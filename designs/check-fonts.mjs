// Regression: the real CLI must resolve all eight faces and draw Latin, Chinese and source marks.
// Run: node designs/check-fonts.mjs (macOS + ImageMagick, as used for the design previews).
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { copyFileSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const dir = mkdtempSync(join(tmpdir(), 'openpencil-font-test-'))
const file = join(dir, 'fonts.fig')
const image = join(dir, 'fonts.png')
const env = { ...process.env, NODE_OPTIONS: `${process.env.NODE_OPTIONS ?? ''} --import=${new URL('./load-local-fonts.mjs', import.meta.url).href}` }
const op = (...args) => execFileSync('openpencil', args, { encoding: 'utf8', env, stdio: ['ignore', 'pipe', 'pipe'] })
const samples = [
  ['SF Pro', 400, 'Library: AI* / Manual+'],
  ['SF Pro', 600, 'Start Dictation'],
  ['SF Pro', 700, 'Session Complete'],
  ['New York', 400, 'What are you listening to?'],
  ['New York', 600, 'keeping time* with the music'],
  ['New York', 700, 'profoundly different'],
  ['PingFang SC', 400, '中文翻译：深刻地；极大地'],
  ['PingFang SC', 600, '与音乐保持节拍一致'],
  ['SF Pro', 700, '________'],
]
try {
  copyFileSync(new URL('./podcast-learning.fig', import.meta.url), file)
  op('eval', file, '-w', '-c', 'figma.currentPage.children.forEach(n => n.remove()); "ok"')
  const jsx = `<Frame name="Font regression" w={500} h={${samples.length * 44 + 110}} bg="#FFFFFF">${samples.map(([family, weight, text], i) => `<Text x={12} y={${i * 44 + 8}} font="${family}" weight={${weight}} size={20} color="#000000">${text}</Text>`).join('')}<Frame name="Settings row" x={0} y={${samples.length * 44}} w={361} h={52} flex="row" items="center" gap={12} px={16}><Rectangle w={30} h={30} /><Frame grow={1} flex="col"><Text name="Row label" font="SF Pro" size={17} lineHeight={22}>Target Level</Text></Frame><Text name="Row value" font="SF Pro" size={17} lineHeight={22}>Use Global (B2)</Text><Rectangle w={17} h={17} /></Frame><Frame x={0} y={${samples.length * 44 + 60}} w={118} h={32} flex="row" justify="center" items="center"><Text name="Segment label" font="SF Pro" weight={600} size={15} lineHeight={20}>Podcast Link</Text></Frame></Frame>`
  const args = join(dir, 'render.json')
  writeFileSync(args, JSON.stringify({ jsx }))
  op('tool', 'call', 'render', file, '--args-file', args, '-w')
  // Read in a fresh CLI process: fallback-width layout used to turn the label into a 44pt block.
  const rowMetrics = () => JSON.parse(op('eval', file, '-c', 'const label=figma.currentPage.findOne(n=>n.name==="Row label"); const value=figma.currentPage.findOne(n=>n.name==="Row value"); const segment=figma.currentPage.findOne(n=>n.name==="Segment label"); ({labelHeight:label.height, labelY:label.parent.y, valueWidth:value.width, valueY:value.y,segmentWidth:segment.width,segmentX:segment.x,segmentY:segment.y})', '--json'))
  const initial = rowMetrics()
  assert.equal(initial.labelHeight, 22, `Cold-open row is misaligned: ${JSON.stringify(initial)}`)
  assert.equal(initial.labelY, initial.valueY, 'Label and value must be vertically aligned')
  assert.ok(initial.segmentWidth < 100, 'Segment must use shaped glyph widths, not the 108pt character estimate')
  assert.ok(Math.abs(initial.segmentX - (118 - initial.segmentWidth) / 2) < 0.01, 'Segment label must be horizontally centered')
  assert.equal(initial.segmentY, 6, 'Segment label must be vertically centered')
  op('eval', file, '-w', '-c', '"save and reopen"')
  assert.deepEqual(rowMetrics(), initial, 'Saving and reopening must preserve text geometry')
  const status = JSON.parse(op('fonts', file, '--json'))
  assert.equal(status.faithful, true, JSON.stringify(status.issues))
  assert.equal(status.faces.length, 8)
  op('export', file, '--font-policy', 'strict', '-o', image)
  for (const [i, [family, weight, text]] of samples.entries()) {
    const mean = Number(execFileSync('magick', [image, '-crop', `500x44+0+${i * 44}`, '-colorspace', 'gray', '-format', '%[fx:mean]', 'info:'], { encoding: 'utf8' }))
    assert.ok(mean < 0.9999, `${family} ${weight} rendered blank (mean=${mean}): ${text}`)
  }
  // Also check the complete deliverable, not just the reduced settings-row reproduction.
  const design = new URL('./podcast-learning.fig', import.meta.url).pathname
  const geometryCode = `const walk=(n,path)=>{const own=n.type==='TEXT'?[{path,text:n.characters,x:+n.x.toFixed(3),y:+n.y.toFixed(3),w:+n.width.toFixed(3),h:+n.height.toFixed(3),px:+n.parent.x.toFixed(3),py:+n.parent.y.toFixed(3)}]:[];return own.concat(n.children?n.children.flatMap((c,i)=>walk(c,path+'/'+i)):[])};figma.currentPage.children.flatMap(n=>walk(n,n.name)).sort((a,b)=>a.path.localeCompare(b.path))`
  const geometry = (path) => JSON.parse(op('eval', path, '-c', geometryCode, '--json'))
  const before = geometry(design)
  const roundtrip = join(dir, 'roundtrip.fig')
  op('eval', design, '-o', roundtrip, '-c', '"roundtrip"')
  const after = geometry(roundtrip)
  assert.equal(after.length, before.length)
  before.forEach((text, i) => assert.deepEqual(after[i], text, `Geometry changed after save/reopen: ${text.path}`))
  console.log(`PASS: 8 local font faces; ${samples.length} visible text samples; centered row/segment; ${before.length} text layers unchanged after save/reopen.`)
} finally {
  rmSync(dir, { recursive: true, force: true })
}
