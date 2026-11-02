// OpenPencil 0.16's CLI has no local-font host. Preload this for the same fonts as the macOS app.
// Used only for these Apple-platform mockups; font files stay outside the project.
import { readFile, realpath, readdir } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { homedir } from 'node:os'
import { pathToFileURL } from 'node:url'

const require = createRequire(await realpath(process.argv[1]))
const { fontManager } = await import(pathToFileURL(require.resolve('@open-pencil/core/text')))
const fontDir = `${homedir()}/Library/Fonts`
// shortcut: uses macOS's Font8 asset layout; update this path if Apple relocates PingFang.
const assets = '/System/Library/AssetsV2/com_apple_MobileAsset_Font8'
const pingFang = (await readdir(assets)).filter((s) => s.endsWith('.asset'))
  .map((s) => `${assets}/${s}/AssetData/PingFang.ttc`)
let collection
for (const path of pingFang) {
  try { collection = await readFile(path); break } catch (error) { if (error.code !== 'ENOENT') throw error }
}
if (!collection) throw new Error('PingFang.ttc not found in the macOS font assets')

// CanvasKit reads only the first face. Move the requested TTC directory there, as OpenPencil's
// desktop/src/fonts/sfnt.rs does; table offsets are absolute, so the outline tables stay unchanged.
function collectionFace(data, postscriptName) {
  if (data.toString('ascii', 0, 4) !== 'ttcf') throw new Error('Expected a TrueType collection')
  for (let i = 0; i < data.readUInt32BE(8); i++) {
    const face = data.readUInt32BE(12 + i * 4)
    const tables = data.readUInt16BE(face + 4)
    for (let j = 0; j < tables; j++) {
      const record = face + 12 + j * 16
      if (data.toString('ascii', record, record + 4) !== 'name') continue
      const start = data.readUInt32BE(record + 8)
      const strings = start + data.readUInt16BE(start + 4)
      for (let k = 0; k < data.readUInt16BE(start + 2); k++) {
        const n = start + 6 + k * 12
        if (data.readUInt16BE(n) !== 3 || data.readUInt16BE(n + 6) !== 6) continue
        const offset = strings + data.readUInt16BE(n + 10)
        const name = Buffer.from(data.subarray(offset, offset + data.readUInt16BE(n + 8))).swap16().toString('utf16le')
        if (name !== postscriptName) continue
        const result = Buffer.from(data)
        data.copy(result, 0, face, face + 12 + tables * 16)
        return result
      }
    }
  }
  throw new Error(`Installed font face not found: ${postscriptName}`)
}

fontManager.setHostFontCatalog([
  { family: 'SF Pro', styles: ['Regular', 'SemiBold', 'Bold'] },
  { family: 'New York', styles: ['Regular', 'SemiBold', 'Bold'] },
  { family: 'PingFang SC', styles: ['Regular', 'SemiBold'] },
])
fontManager.setHostFontLoader(async (family, style) => {
  let data
  if (family === 'SF Pro' || family === 'New York') {
    data = await readFile(`${fontDir}/${family === 'SF Pro' ? 'SF-Pro' : 'NewYork'}.ttf`)
  } else if (family === 'PingFang SC') {
    data = collectionFace(collection, `PingFangSC-${style === 'SemiBold' ? 'Semibold' : style}`)
  } else return null
  return data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength)
})
fontManager.setFallbackUserAgent('Macintosh')

// The CLI recomputes auto-layout while reading .fig, before its usual text measurer starts.
// Install the real shaper first: fallback character-width estimates otherwise change row geometry.
const { initCanvasKit } = await import(pathToFileURL(require.resolve('@open-pencil/core/io/formats/raster')))
const { SkiaRenderer } = await import(pathToFileURL(require.resolve('@open-pencil/core/canvas')))
const { installTextMeasurer } = await import(pathToFileURL(require.resolve('@open-pencil/core/layout')))
const ck = await initCanvasKit()
const surface = ck.MakeSurface(1, 1)
if (!surface) throw new Error('Cannot initialize the font measurement surface')
const renderer = new SkiaRenderer(ck, surface)
await renderer.loadFonts()
for (const [family, styles] of [['SF Pro', ['Regular', 'SemiBold', 'Bold']], ['New York', ['Regular', 'SemiBold', 'Bold']], ['PingFang SC', ['Regular', 'SemiBold']]]) {
  for (const style of styles) {
    if (!await fontManager.loadLocalFont(family, style)) throw new Error(`Cannot load ${family} ${style}`)
  }
}
installTextMeasurer((node, maxWidth) => renderer.measureTextNode(node, maxWidth))
