// Initial scaffold: regenerating overwrites manual OpenPencil edits. The edited .fig is authoritative.
// Usage: node designs/generate.mjs [screen numbers, e.g. 3,4]
// HIG basis: .agents/skills/apple-design/references/hig (typography Large scale, 44pt targets, 4.5:1 contrast,
// Liquid Glass only on floating controls, sheets instead of popovers on iPhone, title-case buttons).
import { execFileSync } from 'node:child_process'
import { writeFileSync, mkdirSync } from 'node:fs'

const W = 393, H = 852, GAP = 80

// Semantic palette. Every text pair checked at >= 4.5:1 (see contrast check at bottom).
const LIGHT = {
  bg: '#F2F2F7', cell: '#FFFFFF', label: '#000000', label2: '#6E6E73', sep: '#C6C6C8', fill: '#E3E3E8',
  accent: '#6D4AFF', onAccent: '#FFFFFF', accentSoft: '#F3F0FF',
  list: '#1F5FD6', ai: '#B54708', manual: '#0F766E',
  key: '#FFF1B8', keyBar: '#E0A800', ok: '#15803D', okSoft: '#DCFCE7', bad: '#C81E1E', badSoft: '#FEE2E2',
  glass: '#FFFFFFB8', glassStroke: '#FFFFFFE6', shadow: '#0000001F', dim: '#00000059',
  kb: '#D1D3D9', keyCap: '#FFFFFF', keyCap2: '#ABB0BA', statusBarDark: false,
}
const DARK = {
  bg: '#000000', cell: '#1C1C1E', label: '#FFFFFF', label2: '#98989F', sep: '#38383A', fill: '#2C2C2E',
  accent: '#A391FF', onAccent: '#000000', accentSoft: '#2A2346',
  list: '#6EA8FF', ai: '#FFA05C', manual: '#4FD1C5',
  key: '#3A3000', keyBar: '#FFD60A', ok: '#4ADE80', okSoft: '#0F2E1A', bad: '#FF7B72', badSoft: '#3A1414',
  glass: '#2C2C2EB8', glassStroke: '#FFFFFF26', shadow: '#00000066', dim: '#00000099',
  kb: '#1B1B1D', keyCap: '#4A4A4C', keyCap2: '#2E2E30', statusBarDark: true,
}
let C = LIGHT

// System families (Dynamic Type in the app). load-local-fonts.mjs makes them available to the CLI.
const UI = 'SF Pro', READ = 'New York', ZH = 'PingFang SC'
// typography.md › Specifications › Large (default)
const T = {
  largeTitle: [34, 700, 41], title2: [22, 700, 28], title3: [20, 600, 25], headline: [17, 600, 22], body: [17, 400, 22],
  callout: [16, 400, 21], subhead: [15, 400, 20], footnote: [13, 400, 18], caption: [12, 400, 16], caption2: [11, 600, 13],
}

// ---------- primitives ----------
const txt = (s, style = 'body', { color = C.label, font = UI, weight, extra = '' } = {}) =>
  `<Text font="${font}" size={${T[style][0]}} weight={${weight ?? T[style][1]}} lineHeight={${T[style][2]}} color="${color}" ${extra}>${s}</Text>`
const icon = (name, size = 20, color = C.label) => `<Icon name="lucide:${name}" size={${size}} color="${color}" />`
const center = 'flex="row" justify="center" items="center"'
const glassFx = (r = 20) => `bg="${C.glass}" effects={[backgroundBlur({ radius: ${r} }), dropShadow({ color: "${C.shadow}", offset: { x: 0, y: 6 }, radius: 20 })]} stroke="${C.glassStroke}" strokeWidth={0.5}`
// Liquid Glass control: 44pt circle, monochrome symbol (toolbars.md › Actions; liquid-glass.md).
const glassBtn = (ic, label = '') => `<Frame name="${label || ic}" w={44} h={44} rounded={22} ${glassFx()} ${center}>${icon(ic, 20, C.label)}</Frame>`
const glassPill = (inner, name = 'Glass pill') => `<Frame name="${name}" h={44} px={16} rounded={22} ${glassFx()} ${center} gap={4}>${inner}</Frame>`
// buttons.md › Style: one prominent (accent background) action per view.
const prominent = (label, { ic = '', w = 'fill', h = 50 } = {}) =>
  `<Frame name="${label}" w="${w}" h={${h}} rounded={${h / 2}} bg="${C.accent}" ${center} gap={8}>${ic ? icon(ic, 18, C.onAccent) : ''}${txt(label, 'headline', { color: C.onAccent })}</Frame>`
const secondary = (label, { ic = '', w = 'fill', h = 50, color = C.label } = {}) =>
  `<Frame name="${label}" w="${w}" h={${h}} rounded={${h / 2}} bg="${C.fill}" ${center} gap={8}>${ic ? icon(ic, 18, color) : ''}${txt(label, 'headline', { color })}</Frame>`
// CEFR level: text, neutral fill (no rainbow: colour stays reserved for item source).
const badge = (lvl) => `<Frame px={6} py={2} rounded={5} bg="${C.fill}">${txt(lvl, 'caption2', { color: C.label })}</Frame>`

// Item source: colour + distinct shape, never colour alone (accessibility.md › Vision).
const SRC = () => ({
  list: { color: C.list, deco: 'solid', ic: 'book-open', mark: '' },
  ai: { color: C.ai, deco: 'wavy', ic: 'sparkles', mark: '*' },
  manual: { color: C.manual, deco: 'dotted', ic: 'hand', mark: '+' },
})
const srcIcon = (src, s = 14) => icon(SRC()[src].ic, s, SRC()[src].color)
const span = (w, src) => { const s = SRC()[src]; return `<Span color="${s.color}" weight={600} textDecoration="underline" textDecorationStyle="${s.deco}" textDecorationColor="${s.color}" textDecorationThickness={2} textUnderlineOffset={4}>${w}</Span>${s.mark ? `<Span color="${s.color}" size={13} weight={700}>${s.mark}</Span>` : ''}` } // trailing mark: a non-colour cue that survives renderers without wavy/dotted underlines
const rich = (s, { size = 20, lh = 30 } = {}) =>
  `<Text w="fill" font="${READ}" size={${size}} lineHeight={${lh}} color="${C.label}">${s.replace(/\[\[(.+?)\|(\w+)\]\]/g, (_, w, src) => span(w, src))}</Text>`

const statusBar = () => {
  const c = C.label
  return `<Frame name="Status bar" w="fill" h={54} flex="row" justify="between" items="center" px={32} pt={6}>
    ${txt('9:41', 'headline', { color: c })}
    <Frame flex="row" gap={6} items="center">${icon('signal', 17, c)}${icon('wifi', 17, c)}${icon('battery-full', 22, c)}</Frame>
  </Frame>`
}
const homeIndicator = (bg = '') => `<Frame name="Home indicator" w="fill" h={34} ${center} ${bg ? `bg="${bg}"` : ''}><Frame w={134} h={5} rounded={3} bg="${C.label}" /></Frame>`
const screen = (name, body, { bg = C.bg, overlay = '' } = {}) =>
  `<Frame name="${name}" w={${W}} h={${H}} flex="col" bg="${bg}" rounded={44} overflow="hidden">${body}${overlay}</Frame>`

// segmented-controls.md: nouns, title case, equal widths.
const segmented = (opts, active) =>
  `<Frame name="Segmented control" w="fill" h={36} flex="row" p={2} gap={2} rounded={18} bg="${C.fill}">${opts.map((o, i) =>
    `<Frame grow={1} h="fill" ${center} rounded={16} ${i === active ? `bg="${C.cell}" shadow="0 1 3 #0000001F"` : ''}>${txt(o, 'subhead', { weight: 600 })}</Frame>`).join('')}</Frame>`

// Inset grouped list (lists-and-tables.md › Style).
const group = (rows, header = '', footer = '') =>
  `<Frame w="fill" flex="col" gap={6}>
    ${header ? `<Frame px={16} flex="col">${txt(header, 'footnote', { color: C.label2, weight: 600 })}</Frame>` : ''}
    <Frame w="fill" flex="col" rounded={20} bg="${C.cell}" overflow="hidden">${rows.join(`<Frame w="fill" h={0.5} pl={16}><Rectangle w="fill" h={0.5} bg="${C.sep}" /></Frame>`)}</Frame>
    ${footer ? `<Frame w="fill" px={16} flex="col">${txt(footer, 'footnote', { color: C.label2, extra: 'w="fill"' })}</Frame>` : ''}
  </Frame>`
const row = (label, value = '', { ic = '', icBg = C.accent, chevron = true, labelColor = C.label } = {}) =>
  `<Frame w="fill" h={52} flex="row" items="center" gap={12} px={16}>
    ${ic ? `<Frame w={30} h={30} rounded={8} bg="${icBg}" ${center}>${icon(ic, 17, '#FFFFFF')}</Frame>` : ''}
    <Frame grow={1} flex="col">${txt(label, 'body', { color: labelColor })}</Frame>
    ${value ? txt(value, 'body', { color: C.label2 }) : ''}
    ${chevron ? icon('chevron-right', 17, C.label2) : ''}
  </Frame>`

// ---------- content ----------
const EP = { title: 'Want to Enjoy Music More? Go for a Run', show: 'The Daily', date: 'Nov 1, 2026', dur: '36:12' }
const art = (s, grad, ic, r = 12) =>
  `<Frame w={${s}} h={${s}} rounded={${r}} fills={[linearGradient([['${grad[0]}', 0], ['${grad[1]}', 1]], { transform: { m00: 0.7, m01: 0.7, m02: 0, m10: -0.7, m11: 0.7, m12: 0.5 } })]} ${center}>${icon(ic, Math.round(s * 0.42), '#FFFFFF')}</Frame>`
const cover = (s = 56, r = 12) => art(s, ['#FF7A59', '#6D4AFF'], 'headphones', r)

const segments = [
  { sp: 'Speaker 1', t: '01:12', s: ['What are you listening to?'] },
  { sp: 'Speaker 2', t: '01:14', key: true, s: [
    'Honestly, it started as a way to [[distract|list]] myself.',
    'But after a few weeks, the music felt [[profoundly|list]] different, almost like my body was [[keeping time|ai]] with it.',
  ] },
  { sp: 'Speaker 1', t: '01:31', s: ['Researchers have a name for that. They call it [[entrainment|list]], and it turns out runners are [[remarkably|manual]] good at it.'] },
]
const segmentBlock = ({ sp, t, key, s }, playing = false) =>
  `<Frame name="Segment" w="fill" flex="col" gap={8}>
    <Frame name="Play paragraph" flex="row" items="center" gap={8} h={32}>
      <Frame w={28} h={28} rounded={14} bg="${playing ? C.accent : C.accentSoft}" ${center}>${icon(playing ? 'pause' : 'play', 13, playing ? C.onAccent : C.accent)}</Frame>
      ${txt(sp, 'footnote', { color: C.label2, weight: 600 })}
      ${txt(t, 'footnote', { color: C.label2, extra: 'fontFeatures={{ tnum: true }}' })}
    </Frame>
    ${s.map((x, i) => key && i === s.length - 1
      ? `<Frame name="Key sentence" w="fill" flex="row" gap={10} py={8} pr={10} pl={0} rounded={8} bg="${C.key}"><Rectangle w={4} h="fill" rounded={2} bg="${C.keyBar}" /><Frame grow={1} flex="col">${rich(x)}</Frame></Frame>`
      : `<Frame w="fill" flex="col">${rich(x)}</Frame>`).join('')}
  </Frame>`
const legend = () => `<Frame name="Legend" w="fill" flex="row" gap={14} px={20} pb={8} items="center">
  ${['list', 'ai', 'manual'].map((k) => `<Text font="${UI}" size={13} color="${C.label2}">${span(k === 'list' ? 'List' : k === 'ai' ? 'AI' : 'Manual', k).replace('weight={600}', 'weight={600} size={13}')}</Text>`).join('')}
  <Frame flex="row" gap={5} items="center"><Rectangle w={4} h={14} rounded={2} bg="${C.keyBar}" />${txt('Key sentence', 'footnote', { color: C.label2 })}</Frame>
</Frame>`

// ---------- screens ----------
function build() {
  const stateTag = (label, color, ic) => `<Frame flex="row" items="center" gap={4}>${icon(ic, 13, color)}${txt(label, 'footnote', { color, weight: 600 })}</Frame>`
  const libraryCard = ({ title, show, meta, state, progress, grad }) => `
  <Frame name="Transcript" w="fill" flex="row" gap={12} p={12} rounded={20} bg="${C.cell}" items="center">
    ${art(64, grad, grad[2])}
    <Frame grow={1} flex="col" gap={3}>
      ${txt(title, 'headline', { extra: 'w="fill" maxLines={2}' })}
      ${txt(`${show} · ${meta}`, 'footnote', { color: C.label2, extra: 'w="fill"' })}
      <Frame w="fill" flex="row" items="center" gap={8} pt={3}>${state}<Frame grow={1} w={0} h={0} />${progress != null ? `<Frame w={64} h={4} rounded={2} bg="${C.fill}"><Frame w={${Math.round(progress * 64)}} h={4} rounded={2} bg="${C.label2}" /></Frame>` : ''}</Frame>
    </Frame>
  </Frame>`

  const library = screen('01 Library', `
  ${statusBar()}
  <Frame name="Toolbar" w="fill" h={52} flex="row" justify="end" items="center" px={16}>${glassBtn('settings', 'Settings')}</Frame>
  <Frame w="fill" flex="col" gap={14} px={16}>
    <Frame flex="col" gap={2} px={4}>${txt('Library', 'largeTitle')}${txt('Target level B2 and above', 'subhead', { color: C.label2 })}</Frame>
    <Frame w="fill" flex="col" gap={10}>
      ${libraryCard({ title: EP.title, show: 'The Daily', meta: '207 segments', state: stateTag('Finding key sentences…', C.ai, 'sparkles'), grad: ['#FF7A59', '#6D4AFF', 'headphones'] })}
      ${libraryCard({ title: 'How Sleep Rewires Memory', show: 'Hidden Brain', meta: '31 words', state: stateTag('12 to practice', C.label2, 'pencil-line'), progress: 0.62, grad: ['#22D3EE', '#2563EB', 'moon'] })}
      ${libraryCard({ title: 'The Economics of Coffee', show: 'Planet Money', meta: '18 words', state: stateTag('AI analysis failed · Retry', C.bad, 'rotate-ccw'), progress: 0.2, grad: ['#F59E0B', '#B45309', 'coffee'] })}
      ${libraryCard({ title: 'TED Talk Notes', show: 'Pasted text', meta: '9 words', state: stateTag('All mastered', C.ok, 'circle-check'), progress: 1, grad: ['#A3A3A3', '#525252', 'file-text'] })}
    </Frame>
  </Frame>`, { overlay: `
  <Frame name="Bottom toolbar" position="absolute" x={16} y={${H - 34 - 56}} w={${W - 32}} flex="row" gap={10} items="center">
    <Frame name="Search" grow={1} h={48} rounded={24} ${glassFx()} flex="row" items="center" gap={8} px={16}>${icon('search', 18, C.label2)}${txt('Search', 'body', { color: C.label2 })}</Frame>
    <Frame name="New Transcript" w={48} h={48} rounded={24} bg="${C.accent}" ${center}>${icon('plus', 24, C.onAccent)}</Frame>
  </Frame>
  <Frame position="absolute" x={0} y={${H - 34}} w={${W}} flex="col">${homeIndicator()}</Frame>` })

  // sheets.md › iOS: Cancel (✕) leading, confirming action trailing; grabber; swipe to dismiss.
  const importSheet = screen('02 Import', `
  ${statusBar()}
  <Frame w="fill" h={8} />
  <Frame name="Sheet" w="fill" grow={1} flex="col" roundedTL={38} roundedTR={38} bg="${C.bg}" gap={18} px={16} pt={6}>
    <Frame w="fill" ${center}><Frame w={36} h={5} rounded={3} bg="${C.sep}" /></Frame>
    <Frame w="fill" flex="row" justify="between" items="center">${glassBtn('x', 'Cancel')}${txt('New Transcript', 'headline')}<Frame name="Import" h={44} px={18} rounded={22} bg="${C.accent}" ${center}>${txt('Import', 'headline', { color: C.onAccent })}</Frame></Frame>
    ${segmented(['Podcast Link', 'Text', 'File'], 0)}
    ${group([`<Frame w="fill" h={52} flex="row" items="center" gap={10} px={16}>${icon('link', 18, C.label2)}${txt('podcasts.apple.com/us/podcast/want-to-enjoy-music…', 'body', { extra: 'grow={1} maxLines={1} truncate' })}${icon('circle-x', 18, C.label2)}</Frame>`],
      'Apple Podcasts Episode', 'In Podcasts, tap Share › Learn to import without copying the link.')}
    <Frame name="Preview" w="fill" flex="col" gap={12} p={16} rounded={20} bg="${C.cell}">
      <Frame w="fill" flex="row" gap={12} items="center">${cover(52, 10)}<Frame grow={1} flex="col" gap={2}>${txt(EP.title, 'headline', { extra: 'w="fill"' })}${txt(`${EP.show} · ${EP.dur}`, 'footnote', { color: C.label2 })}</Frame></Frame>
      <Rectangle w="fill" h={0.5} bg="${C.sep}" />
      ${[['circle-check', C.ok, 'Transcript found · 207 segments'], ['loader', C.label2, 'Looking for the episode audio…'], ['circle-dashed', C.label2, 'Words at B2 and above will be marked']].map(([i, c, l]) =>
        `<Frame flex="row" gap={10} items="center">${icon(i, 18, c)}${txt(l, 'subhead', { color: i === 'circle-check' ? C.label : C.label2 })}</Frame>`).join('')}
    </Frame>
    ${group([row('Target Level', 'Use Global (B2)', { ic: 'gauge', icBg: '#0A84FF' })], 'This Transcript')}
  </Frame>
  ${homeIndicator(C.bg)}`, { bg: C.statusBarDark ? '#000000' : '#D8D8DE' })

  const readerHeader = (activeTab = 0) => `
  ${statusBar()}
  <Frame name="Toolbar" w="fill" h={52} flex="row" items="center" justify="between" px={16}>
    ${glassBtn('chevron-left', 'Back')}
    <Frame flex="row" gap={10}>${glassPill(txt('B2+', 'headline') + icon('chevron-down', 14, C.label2), 'Target Level')}${glassBtn('ellipsis', 'More')}</Frame>
  </Frame>
  <Frame w="fill" flex="col" gap={12} px={16} pb={12}>
    <Frame flex="row" gap={12} items="center">${cover(48, 10)}<Frame grow={1} flex="col" gap={1}>${txt(EP.title, 'headline', { extra: 'w="fill" maxLines={1} truncate' })}${txt(`${EP.show} · ${EP.dur} · 24 words`, 'footnote', { color: C.label2 })}</Frame></Frame>
    ${segmented(['Transcript', 'Items'], activeTab)}
  </Frame>`
  const transcript = () => `
  ${legend()}
  <Frame name="Transcript" w="fill" flex="col" gap={22} px={20} pt={18} bg="${C.cell}" grow={1} roundedTL={28} roundedTR={28}>
    ${segmentBlock(segments[0])}${segmentBlock(segments[1], true)}${segmentBlock(segments[2])}
  </Frame>`
  // Floating functional layer in Liquid Glass (liquid-glass.md › Where the material belongs).
  const player = `
  <Frame name="Player" position="absolute" x={16} y={${H - 34 - 50 - 10 - 60}} w={${W - 32}} h={60} rounded={30} ${glassFx(24)} flex="row" items="center" gap={6} px={8}>
    <Frame name="Back 15 Seconds" w={44} h={44} ${center}>${icon('rotate-ccw', 20)}</Frame>
    <Frame name="Pause" w={44} h={44} rounded={22} bg="${C.label}" ${center}>${icon('pause', 18, C.cell)}</Frame>
    <Frame name="Forward 15 Seconds" w={44} h={44} ${center}>${icon('rotate-cw', 20)}</Frame>
    <Frame grow={1} flex="col" gap={4} pr={4}><Frame w="fill" h={4} rounded={2} bg="${C.fill}"><Frame w={40} h={4} rounded={2} bg="${C.label}" /></Frame><Frame w="fill" flex="row" justify="between">${txt('01:16', 'caption', { color: C.label2, extra: 'fontFeatures={{ tnum: true }}' })}${txt('−34:56', 'caption', { color: C.label2, extra: 'fontFeatures={{ tnum: true }}' })}</Frame></Frame>
    <Frame name="Playback Speed" w={44} h={44} ${center}>${txt('1×', 'headline')}</Frame>
  </Frame>
  <Frame name="Bottom" flex="col" position="absolute" x={16} y={${H - 34 - 50}} w={${W - 32}}>${prominent('Start Dictation', { ic: 'pencil-line' })}</Frame>
  <Frame position="absolute" x={0} y={${H - 34}} w={${W}} flex="col">${homeIndicator()}</Frame>`

  const reader = screen('03 Reader', readerHeader(0) + transcript(), { overlay: player })

  // popovers.md › Mobile: no popovers in compact width, so a medium-detent sheet.
  const wordSheet = `
  <Rectangle position="absolute" x={0} y={0} w={${W}} h={${H}} bg="${C.dim}" />
  <Frame name="Word sheet (medium detent)" position="absolute" x={8} y={${H - 410}} w={${W - 16}} h={402} flex="col" gap={12} px={20} pt={6} pb={20} rounded={38} bg="${C.cell}">
    <Frame w="fill" ${center}><Frame w={36} h={5} rounded={3} bg="${C.sep}" /></Frame>
    <Frame w="fill" flex="row" items="center" gap={8}>
      ${txt('profoundly', 'title2', { font: READ })}${badge('B2')}<Frame grow={1} w={0} h={0} />
      ${glassBtn('volume-2', 'Pronounce')}${glassBtn('x', 'Close')}
    </Frame>
    ${txt('profound · adverb · /prəˈfaʊndli/', 'subhead', { color: C.label2 })}
    ${txt('深刻地；极大地', 'title3', { font: ZH })}
    ${txt('In a way that is very great or intense.', 'body', { color: C.label2, extra: 'w="fill"' })}
    <Frame flex="row" gap={6} items="center">${srcIcon('list')}${txt('Marked from the CEFR-J word list', 'footnote', { color: C.label2 })}</Frame>
    <Frame w="fill" grow={1} h={0} />
    <Frame w="fill" flex="row" gap={10}>
      ${secondary('Remove', { ic: 'x', color: C.bad })}
      ${secondary('Show in Items', { ic: 'list' })}
    </Frame>
  </Frame>`
  const readerWord = screen('04 Reader · Word', readerHeader(0) + transcript(), { overlay: player + wordSheet })

  // generative-ai.md › Transparency + Outputs: labelled, may be wrong, can regenerate.
  const sentenceSheet = `
  <Rectangle position="absolute" x={0} y={0} w={${W}} h={${H}} bg="${C.dim}" />
  <Frame name="Sentence sheet" position="absolute" x={0} y={300} w={${W}} h={${H - 300}} flex="col" gap={14} px={20} pt={6} pb={34} roundedTL={38} roundedTR={38} bg="${C.cell}">
    <Frame w="fill" ${center}><Frame w={36} h={5} rounded={3} bg="${C.sep}" /></Frame>
    <Frame w="fill" flex="row" justify="between" items="center">${glassBtn('volume-2', 'Play Paragraph')}${txt('Sentence', 'headline')}${glassBtn('x', 'Close')}</Frame>
    ${rich('But after a few weeks, the music felt [[profoundly|list]] different, almost like my body was [[keeping time|ai]] with it.')}
    <Frame name="Translation" w="fill" flex="col" gap={6} p={14} rounded={16} bg="${C.bg}">
      <Frame flex="row" gap={6} items="center">${icon('languages', 14, C.label2)}${txt('Translation', 'footnote', { color: C.label2, weight: 600 })}</Frame>
      ${txt('但几周之后，音乐给人的感觉截然不同，就好像我的身体在跟着它打拍子。', 'body', { font: ZH, extra: 'w="fill" lineHeight={26}' })}
    </Frame>
    <Frame name="AI explanation" w="fill" flex="col" gap={8} p={14} rounded={16} bg="${C.bg}">
      <Frame w="fill" flex="row" gap={6} items="center">${icon('sparkles', 14, C.ai)}${txt('AI Explanation', 'footnote', { color: C.ai, weight: 600 })}<Frame grow={1} w={0} h={0} /><Frame name="Regenerate" h={32} px={10} flex="row" items="center" gap={4}>${icon('rotate-ccw', 14, C.label2)}${txt('Regenerate', 'footnote', { color: C.label2, weight: 600 })}</Frame></Frame>
      ${txt('“keep time with” 意为“与…保持节拍一致”。almost like 引出一个比喻，说明身体的节奏与音乐同步。', 'callout', { font: ZH, extra: 'w="fill" lineHeight={24}' })}
      ${txt('Generated by AI. It can make mistakes.', 'footnote', { color: C.label2 })}
    </Frame>
  </Frame>`
  const readerSentence = screen('05 Reader · Sentence', readerHeader(0) + transcript(), { overlay: player + sentenceSheet })

  const itemRow = (w, lvl, src, gloss, ctx, box, removed = false) => `
  <Frame name="Item" w="fill" flex="row" items="center" gap={12} px={16} py={12}>
    ${srcIcon(src, 18)}
    <Frame grow={1} flex="col" gap={3}>
      <Frame flex="row" gap={6} items="center">${txt(w, 'headline', { color: removed ? C.label2 : C.label })}${lvl ? badge(lvl) : ''}${txt(gloss, 'subhead', { font: ZH, color: C.label2 })}</Frame>
      ${txt(ctx, 'footnote', { color: C.label2, font: READ, extra: 'w="fill" maxLines={1} truncate' })}
    </Frame>
    ${removed ? `<Frame name="Restore" h={32} px={12} rounded={16} bg="${C.accentSoft}" ${center}>${txt('Restore', 'footnote', { color: C.accent, weight: 600 })}</Frame>` : txt(box, 'footnote', { color: C.label2 })}
  </Frame>`
  const chip = (label, active, src) => `<Frame h={34} px={14} rounded={17} bg="${active ? C.label : C.cell}" flex="row" items="center" gap={6}>${src ? srcIcon(src, 13) : ''}${txt(label, 'subhead', { weight: 600, color: active ? C.cell : C.label })}</Frame>`
  const items = screen('06 Items', readerHeader(1) + `
  <Frame name="Filters" w="fill" flex="row" gap={8} px={16} pb={14}>${chip('All 24', true)}${chip('List 17', false, 'list')}${chip('AI 5', false, 'ai')}${chip('Manual 2', false, 'manual')}</Frame>
  <Frame w="fill" flex="col" gap={22} px={16}>
    ${group([
      itemRow('distract', 'B1', 'list', '使分心', '…it started as a way to distract myself.', 'Box 3'),
      itemRow('profoundly', 'B2', 'list', '深刻地', '…the music felt profoundly different…', 'Box 2'),
      itemRow('keeping time', '', 'ai', '打拍子', '…like my body was keeping time with it.', 'New'),
      itemRow('entrainment', 'C2', 'list', '同步', 'They call it entrainment, and it turns…', 'New'),
      itemRow('remarkably', 'B2', 'manual', '非常地', '…runners are remarkably good at it.', 'Box 1'),
    ], '24 Items · Swipe to Remove')}
    ${group([itemRow('cadence', 'C1', 'list', '节奏', '…matching your cadence to the beat…', '', true)], 'Removed')}
  </Frame>`)

  // Keyboard: answer entry happens with the keyboard up, so content must fit above it.
  const keyboard = () => {
    const k = (ch, w = 'grow={1}', bg = C.keyCap, color = C.label) => `<Frame ${w} h={42} rounded={6} bg="${bg}" ${center} shadow="0 1 0 #0000004D">${ch.length === 1 ? txt(ch, 'title3', { weight: 400, color }) : ch}</Frame>`
    const keys = (s) => [...s].map((c) => k(c)).join('')
    return `<Frame name="Keyboard" w="fill" flex="col" gap={11} px={3} pt={8} bg="${C.kb}">
      <Frame w="fill" flex="row" gap={6}>${keys('qwertyuiop')}</Frame>
      <Frame w="fill" flex="row" gap={6} px={19}>${keys('asdfghjkl')}</Frame>
      <Frame w="fill" flex="row" gap={6}>${k(icon('arrow-big-up', 20), 'w={44}', C.keyCap2)}<Frame w={8} h={0} />${keys('zxcvbnm')}<Frame w={8} h={0} />${k(icon('delete', 20), 'w={44}', C.keyCap2)}</Frame>
      <Frame w="fill" flex="row" gap={6}>${k(txt('123', 'body'), 'w={92}', C.keyCap2)}${k(txt('space', 'body'))}${k(txt('Check', 'body', { weight: 600, color: C.onAccent }), 'w={92}', C.accent)}</Frame>
      ${homeIndicator()}
    </Frame>`
  }
  const dictTop = (attempt) => `
  ${statusBar()}
  <Frame name="Toolbar" w="fill" h={52} flex="row" items="center" gap={14} px={16}>
    ${glassBtn('x', 'End Session')}
    <Frame grow={1} h={6} rounded={3} bg="${C.fill}"><Frame w={${Math.round(0.29 * 240)}} h={6} rounded={3} bg="${C.accent}" /></Frame>
    ${txt('7 of 24', 'subhead', { color: C.label2, weight: 600, extra: 'fontFeatures={{ tnum: true }}' })}
  </Frame>
  <Frame w="fill" flex="row" items="center" gap={8} px={20} pt={4}>${txt(attempt, 'subhead', { weight: 600, color: attempt === 'Answer' ? C.bad : C.accent })}<Frame grow={1} w={0} h={0} />${badge('B2')}${txt('Box 2', 'footnote', { color: C.label2 })}</Frame>`
  const audioCard = `
    <Frame name="Audio" w="fill" flex="row" items="center" gap={12} p={12} rounded={20} bg="${C.cell}">
      <Frame name="Play Clip" w={44} h={44} rounded={22} bg="${C.accentSoft}" ${center}>${icon('play', 20, C.accent)}</Frame>
      <Frame grow={1} flex="col" gap={4}>
        <Frame w="fill" h={24} flex="row" items="center" gap={3}>${[8, 14, 20, 12, 22, 16, 10, 18, 24, 14, 9, 20, 12, 18, 10, 22, 15, 8, 20, 12, 17, 10, 21, 13].map((h, i) => `<Rectangle w={3} h={${h}} rounded={2} bg="${i < 9 ? C.accent : C.sep}" />`).join('')}</Frame>
        ${txt('Paragraph · 01:14 – 01:31', 'caption', { color: C.label2 })}
      </Frame>
    </Frame>`
  const cloze = (state) => `
    <Frame name="Sentence" w="fill" flex="col" p={16} rounded={20} bg="${C.cell}">
      <Text w="fill" font="${READ}" size={20} lineHeight={30} color="${C.label}">But after a few weeks, the music felt <Span font="${state === 'reveal' ? READ : UI}" color="${state === 'reveal' ? C.bad : C.accent}" weight={700}>${state === 'reveal' ? 'profoundly' : '________'}</Span> different, almost like my body was keeping time with it.</Text>
    </Frame>`
  // text-fields.md: hint in the field, Clear button trailing.
  const field = (value, wrong) => `<Frame name="Answer" w="fill" h={52} flex="row" items="center" gap={10} px={16} rounded={14} bg="${C.cell}" stroke="${wrong ? C.bad : C.accent}" strokeWidth={2}>
    ${txt(value || 'Type the missing word', 'title3', { weight: value ? 600 : 400, color: value ? (wrong ? C.bad : C.label) : C.label2, extra: 'grow={1}' })}
    ${wrong ? `<Frame flex="row" gap={4} items="center">${icon('circle-x', 16, C.bad)}${txt('Try again', 'footnote', { color: C.bad, weight: 600 })}</Frame>` : `<Rectangle w={2} h={24} bg="${C.accent}" />`}
  </Frame>`
  const hintMask = (word) => {
    const show = (i) => i === 0 || i === word.length - 1 || i % 3 === 0
    return `<Frame name="Hint" w="fill" flex="col" gap={6}>
      ${txt('Hint: first, last and every third letter', 'footnote', { color: C.label2, weight: 600 })}
      <Frame w="fill" flex="row" gap={5}>${[...word].map((ch, i) =>
        `<Frame grow={1} h={36} rounded={8} bg="${show(i) ? C.accentSoft : C.cell}" stroke="${show(i) ? C.accent : C.sep}" strokeWidth={1} ${center}>${txt(show(i) ? ch : '', 'title3', { color: C.accent })}</Frame>`).join('')}</Frame>
    </Frame>`
  }
  const dictInput = (n, attempt, value, wrong, hint) => screen(`0${n} Dictation · ${attempt}`, `
  ${dictTop(attempt)}
  <Frame w="fill" grow={1} flex="col" gap={12} px={16} pt={10}>${audioCard}${cloze('blank')}${hint}${field(value, wrong)}</Frame>
  ${keyboard()}`)
  const dict1 = dictInput(7, 'First Try', 'profund', false, txt('Spelling must match. Capitals and apostrophes don’t matter.', 'footnote', { color: C.label2, extra: 'w="fill"' }))
  const dict2 = dictInput(8, 'Second Try', 'profundly', true, hintMask('profoundly'))
  const dict3 = screen('09 Dictation · Answer', `
  ${dictTop('Answer')}
  <Frame w="fill" grow={1} flex="col" gap={12} px={16} pt={10}>
    ${audioCard}${cloze('reveal')}
    <Frame name="Answer card" w="fill" flex="col" gap={6} p={16} rounded={20} bg="${C.cell}">
      <Frame flex="row" gap={8} items="center">${txt('profoundly', 'title2', { font: READ })}${icon('volume-2', 18, C.label2)}</Frame>
      ${txt('深刻地；极大地', 'headline', { font: ZH })}
      ${txt('In a way that is very great or intense.', 'subhead', { color: C.label2 })}
      <Frame flex="row" gap={6} items="center" pt={6}>${txt('Your tries:', 'footnote', { color: C.label2 })}${txt('profund', 'footnote', { color: C.bad, weight: 600, extra: 'textDecoration="strikethrough"' })}${txt('profundly', 'footnote', { color: C.bad, weight: 600, extra: 'textDecoration="strikethrough"' })}</Frame>
    </Frame>
    <Frame w="fill" grow={1} h={0} />
    ${txt('Back to Box 1 · due tomorrow', 'footnote', { color: C.label2, extra: 'w="fill" textAlign="center"' })}
    ${prominent('Next Word', { ic: 'arrow-right' })}
  </Frame>
  ${homeIndicator()}`)

  const stat = (n, label, color, ic) => `<Frame grow={1} flex="col" items="center" gap={4} py={14} rounded={20} bg="${C.cell}">${icon(ic, 18, color)}${txt(n, 'largeTitle', { color: C.label })}${txt(label, 'footnote', { color: C.label2, weight: 600 })}</Frame>`
  const done = screen('10 Session Complete', `
  ${statusBar()}
  <Frame w="fill" grow={1} flex="col" gap={20} px={16} pt={36} items="center">
    <Frame w={88} h={88} rounded={44} bg="${C.okSoft}" ${center}>${icon('party-popper', 40, C.ok)}</Frame>
    <Frame flex="col" items="center" gap={4}>${txt('Session Complete', 'title2')}${txt('24 words in 11 minutes', 'subhead', { color: C.label2 })}</Frame>
    <Frame w="fill" flex="row" gap={10}>${stat('16', 'First Try', C.ok, 'circle-check')}${stat('5', 'Second Try', C.accent, 'lightbulb')}${stat('3', 'Shown', C.bad, 'eye')}</Frame>
    ${group([
      itemRow('profoundly', 'B2', 'list', '深刻地', '…the music felt profoundly different…', 'Box 1'),
      itemRow('entrainment', 'C2', 'list', '同步', 'They call it entrainment…', 'Box 1'),
      itemRow('keeping time', '', 'ai', '打拍子', '…my body was keeping time with it.', 'Box 1'),
    ], 'Missed Words')}
    <Frame w="fill" grow={1} h={0} />
    <Frame w="fill" flex="col" gap={10} pb={4}>${prominent('Practice Missed Words', { ic: 'repeat' })}${secondary('Done')}</Frame>
  </Frame>
  ${homeIndicator()}`)

  // settings.md: few, infrequently changed options; privacy disclosure next to the AI provider.
  const settings = screen('11 Settings', `
  ${statusBar()}
  <Frame name="Toolbar" w="fill" h={52} flex="row" items="center" px={16}>${glassBtn('chevron-left', 'Back')}</Frame>
  <Frame w="fill" flex="col" gap={20} px={16}>
    <Frame px={4} flex="col">${txt('Settings', 'largeTitle')}</Frame>
    ${group([row('Target Level', 'B2', { ic: 'gauge', icBg: '#0A84FF' })], 'Learning', 'Words at or above this level are marked. Each transcript can override it.')}
    ${group([row('Provider', 'api.openai.com', { ic: 'server', icBg: '#5E5CE6' }), row('Model', 'gpt-4.1', { ic: 'cpu', icBg: '#5E5CE6' }), row('API Key', 'In Keychain', { ic: 'key-round', icBg: '#5E5CE6' }), row('Test Connection', '', { ic: 'plug-zap', icBg: '#30B0C7', chevron: false, labelColor: C.accent })], 'AI', 'Transcript text is sent to this provider for analysis. Audio stays on your iPhone.')}
    ${group([row('Voice', 'Ava (US)', { ic: 'audio-lines', icBg: '#FF9500' }), row('Speaking Rate', '0.9×', { ic: 'gauge', icBg: '#FF9500' })], 'Speech')}
    ${group([row('Downloaded Audio', '214 MB', { ic: 'hard-drive', icBg: '#8E8E93' }), row('Acknowledgments', '', { ic: 'book-open', icBg: '#8E8E93' })], 'Storage and About')}
  </Frame>`)

  return [library, importSheet, reader, readerWord, readerSentence, items, dict1, dict2, dict3, done, settings]
}

// Self-check: every text/background pair used above meets WCAG 4.5:1 (accessibility.md › Vision).
const lum = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16) / 255).map((v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4)).reduce((s, v, i) => s + v * [0.2126, 0.7152, 0.0722][i], 0)
const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05) }
for (const [n, p] of [['light', LIGHT], ['dark', DARK]]) {
  for (const [f, b] of [['label2', 'cell'], ['label2', 'bg'], ['accent', 'cell'], ['onAccent', 'accent'], ['list', 'cell'], ['ai', 'cell'], ['ai', 'bg'], ['manual', 'cell'], ['list', 'key'], ['ai', 'key'], ['ok', 'cell'], ['bad', 'cell'], ['accent', 'accentSoft'], ['label', 'fill']]) {
    const r = ratio(p[f], p[b])
    if (r < 4.5) throw new Error(`${n}: ${f} on ${b} is ${r.toFixed(2)}:1`)
  }
}
console.log('contrast check passed')

// ---------- render (headless into the .fig; the app's save path was unreliable) ----------
const FILE = new URL('./podcast-learning.fig', import.meta.url).pathname
const PNG = new URL('./png/', import.meta.url).pathname
const env = { ...process.env, NODE_OPTIONS: `${process.env.NODE_OPTIONS ?? ''} --import=${new URL('./load-local-fonts.mjs', import.meta.url).href}` }
const op = (...a) => execFileSync('openpencil', a, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], env })
const only = process.argv[2] ? process.argv[2].split(',').map(Number) : null

const jobs = []
for (const [mode, palette, y0] of [['', LIGHT, 0], [' · Dark', DARK, 2 * (H + 140) + 120]]) {
  C = palette
  build().forEach((jsx, i) => {
    if (only && !only.includes(i + 1)) return
    jsx = jsx.replace(/name="([^"]+)"/, (_, n) => `name="${n}${mode}"`) // first name attr = screen frame
    jobs.push({ name: jsx.match(/name="([^"]+)"/)[1], jsx, x: (i % 6) * (W + GAP), y: y0 + Math.floor(i / 6) * (H + 140) })
  })
}
// Full run clears the page; a partial run replaces only the screens it renders.
op('eval', FILE, '-w', '-c', `const names = ${JSON.stringify(only ? jobs.map((j) => j.name) : null)}; figma.currentPage.children.filter(n => !names || names.includes(n.name)).forEach(n => n.remove()); 'ok'`)
mkdirSync(PNG, { recursive: true })
for (const { name, jsx, x, y } of jobs) {
  writeFileSync('/tmp/op-args.json', JSON.stringify({ jsx, x, y }))
  for (let t = 1; ; t++) {
    try { op('tool', 'call', 'render', FILE, '--args-file', '/tmp/op-args.json', '-w'); break }
    catch (e) { if (t === 4 || !/fetch failed/.test(e.stderr)) throw new Error(`${name}: ${e.stderr}`); execFileSync('sleep', ['2']) } // Iconify fetches are flaky
  }
  const id = op('find', FILE, '--name', name, '--json').match(/"id":\s*"([^"]+)"/)[1]
  const slug = name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/-$/, '')
  op('export', FILE, '--node', id, '--font-policy', 'strict', '-o', `${PNG}${slug}.png`)
  console.log('rendered', name)
}
