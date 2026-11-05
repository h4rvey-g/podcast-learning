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
  const geometryCode = `const walk=(n,path)=>{const own=n.type==='TEXT'?[{path,text:n.characters,x:+n.x.toFixed(3),y:+n.y.toFixed(3),w:+n.width.toFixed(3),h:+n.height.toFixed(3),px:+n.parent.x.toFixed(3),py:+n.parent.y.toFixed(3)}]:[];return own.concat(n.children?n.children.flatMap((c,i)=>walk(c,path+'/'+i)):[])};figma.root.children.flatMap(p=>p.children.flatMap(n=>walk(n,p.name+"/"+n.name))).sort((a,b)=>a.path.localeCompare(b.path))`
  const geometry = (path) => JSON.parse(op('eval', path, '-c', geometryCode, '--json'))
  const before = geometry(design)
  const roundtrip = join(dir, 'roundtrip.fig')
  op('eval', design, '-o', roundtrip, '-c', '"roundtrip"')
  const after = geometry(roundtrip)
  assert.equal(after.length, before.length)
  before.forEach((text, i) => assert.deepEqual(after[i], text, `Geometry changed after save/reopen: ${text.path}`))
  const inlineStates = JSON.parse(op('eval', design, '-c', `
    figma.root.children.flatMap(p=>p.children.filter(f=>/^0[78] |^1[23] /.test(f.name)).map(f=>{
      const card=f.findOne(n=>n.name==='Inline paragraph editor');
      const flow=card?.findOne(n=>n.name==='Paragraph flow — inputs remain in reading order');
      const letters=flow?.findAll(n=>/^(Fixed hint |Editable letter )/.test(n.name))??[];
      const overlaps=[];
      for(let i=0;i<(flow?.children.length??0);i++) for(let j=i+1;j<flow.children.length;j++) {
        const a=flow.children[i],b=flow.children[j];
        if(Math.min(a.x+a.width,b.x+b.width)-Math.max(a.x,b.x)>0.1&&Math.min(a.y+a.height,b.y+b.height)-Math.max(a.y,b.y)>0.1) overlaps.push([a.name,b.name]);
      }
      return {name:f.name,
        comment:openpencil.getComments({resolved:false}).filter(c=>c.text.startsWith('One round per paragraph. Both attempts')&&c.page.id===p.id&&c.position.x>=f.x&&c.position.x<f.x+f.width&&c.position.y>=f.y&&c.position.y<f.y+f.height).length,
        card:!!card,fields:flow?.findAll(n=>n.name.startsWith('Inline blank ')).length??0,
        fixed:letters.filter(n=>n.name.startsWith('Fixed hint ')).length,
        editable:letters.filter(n=>n.name.startsWith('Editable letter ')).length,
        boxes:letters.filter(n=>n.strokes.length||n.fills.length).length,
        underscores:flow?.findAll(n=>n.type==='TEXT'&&n.name==='Missing letter underscore'&&n.characters==='_').length??0,
        markers:f.findAll(n=>n.type==='TEXT'&&/\\[\\d+\\]/.test(n.characters)).length,
        legacy:f.findAll(n=>n.name==='Answer'||n.name==='Hint'||/^Blank [12]( —|$)/.test(n.name)).length,
        overlaps,overflow:flow?.children.filter(n=>n.x < -0.1 || n.y < -0.1 || n.x+n.width > flow.width+0.1 || n.y+n.height > flow.height+0.1).map(n=>n.name)??[]
      };
    }))`, '--json'))
  assert.equal(inlineStates.length, 8, 'Both appearances of all four input states must exist')
  for (const state of inlineStates) {
    assert.ok(state.card, `${state.name}: missing inline paragraph editor`)
    assert.equal(state.comment, 1, `${state.name}: interaction note must remain on this screen after reopening`)
    assert.equal(state.legacy, 0, `${state.name}: isolated answer field or hint row remains`)
    assert.equal(state.markers, 0, `${state.name}: visible blank numbers must be removed`)
    assert.equal(state.boxes, 0, `${state.name}: retry letters must not have boxes or fills`)
    assert.deepEqual(state.overlaps, [], `${state.name}: inline words overlap`)
    assert.deepEqual(state.overflow, [], `${state.name}: paragraph flow clips or overflows`)
    assert.equal(state.fields, state.name.startsWith('12 ') ? 2 : 1, `${state.name}: inputs must live inside the paragraph flow`)
    if (/^08 |^13 /.test(state.name)) {
      assert.equal(state.fixed, 4, `${state.name}: keep given hint letters fixed`)
      assert.equal(state.editable, 6, `${state.name}: missing editable letters`)
      assert.equal(state.underscores, 5, `${state.name}: show underscores for the five still-missing letters`)
    }
  }
  const waveforms = JSON.parse(op('eval', design, '-c', `figma.root.children.flatMap(p=>p.children.filter(f=>/^0[789] |^1[23] /.test(f.name)).map(f=>{const wave=f.findOne(n=>n.name==='Seekable paragraph waveform — tap or drag');const audio=f.findOne(n=>n.name==='Audio');return {name:f.name,height:wave?.height,overlap:audio?.parent.children.some(n=>n!==audio&&Math.min(n.x+n.width,audio.x+audio.width)-Math.max(n.x,audio.x)>0.1&&Math.min(n.y+n.height,audio.y+audio.height)-Math.max(n.y,audio.y)>0.1),head:!!wave?.findOne(n=>n.name==='Playback position — draggable playhead'),bars:wave?.findAll(n=>n.name.startsWith('Unplayed audio bar ')).length}}))`, '--json'))
  assert.equal(waveforms.length, 10)
  for (const wave of waveforms) {
    assert.ok(wave.height >= 44 && wave.head, `${wave.name}: waveform needs a 44pt seek target and playhead`)
    assert.equal(wave.bars, 28, `${wave.name}: waveform must fill the audio card`)
    assert.equal(wave.overlap, false, `${wave.name}: taller audio card must not overlap the paragraph`)
  }
  const speech = JSON.parse(op('eval', design, '-c', `
    const page=figma.root.children.find(p=>p.name==='Speech');
    const settings=figma.root.children.flatMap(p=>p.children.filter(f=>/^(11 |17 |21 )/.test(f.name)));
    const layouts=[];
    for(const f of [...settings,...(page?.children??[])]) {
      for(const n of f.findAll(n=>n.type==='FRAME'&&n.layoutMode==='VERTICAL')) {
        const children=n.children.filter(c=>c.layoutPositioning!=='ABSOLUTE');
        for(let i=1;i<children.length;i++) if(children[i].y<children[i-1].y+children[i-1].height-0.1) layouts.push(f.name+'/'+n.name);
      }
    }
    ({
      settings:settings.map(f=>({name:f.name,speech:f.findAll(n=>n.type==='TEXT'&&n.characters==='Speech').length,legacy:f.findAll(n=>n.type==='TEXT'&&/^(Voice|Speaking Rate)$/.test(n.characters)).length})),
      screens:page?.children.map(f=>({name:f.name,width:f.width,height:f.height})),
      models:page?.children.filter(f=>f.name.startsWith('27 ')).map(f=>f.findAll(n=>n.name.startsWith('Model eleven-')).length),
      voices:page?.children.filter(f=>f.name.startsWith('28 ')).map(f=>({rows:f.findAll(n=>/^Voice [a-z]+/.test(n.name)).length,selected:f.findAll(n=>n.name==='Selected voice checkmark'&&n.height===18).length,buttons:f.findAll(n=>/^(Play|Stop) [A-Z][a-z]+ Sample$/.test(n.name)&&n.width===44&&n.height===44).length})),
      notes:figma.root.children.flatMap(p=>p.children.filter(f=>/^(11 |17 |18 |21 |22 |25 |26 |27 |28 )/.test(f.name))).flatMap(f=>f.findAll(n=>n.type==='TEXT'&&/^Words at or above|^Audio only by default|^Thinking effort controls|^Speech uses its own|^Provider Default leaves|^Higher effort may|^Audio is sent to Azure|^A lost response may/.test(n.characters)).map(n=>n.characters)),
      layouts
    })`, '--json'))
  assert.equal(speech.settings.length, 6)
  for (const state of speech.settings) {
    assert.equal(state.speech, 1, `${state.name}: exactly one Speech navigation row`)
    assert.equal(state.legacy, 0, `${state.name}: voice and rate belong inside Speech`)
  }
  assert.equal(speech.screens.length, 8, 'Four Speech states in both appearances')
  assert.ok(speech.screens.every(s => s.width === 393 && s.height === 852))
  assert.deepEqual(speech.models, [9, 9])
  assert.ok(speech.voices.every(s => s.rows === 21 && s.buttons === 21 && s.selected === 1))
  assert.deepEqual(speech.notes, [], 'No explanatory settings footnotes')
  assert.deepEqual(speech.layouts, [], 'Settings and speech rows must not overlap')
  console.log(`PASS: 8 local font faces; ${samples.length} visible text samples; centered row/segment; ${before.length} text layers unchanged after save/reopen; 8 unnumbered inline input states; 10 seekable waveforms; 8 Speech states, single-row navigation, 44pt sample controls, no footnotes or overlapping rows.`)
} finally {
  rmSync(dir, { recursive: true, force: true })
}
