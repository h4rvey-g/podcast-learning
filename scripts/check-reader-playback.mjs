// Exercise the real reader paragraph builder and highlight renderer on macOS.
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const reader = readFileSync(new URL('../PodcastLearning/Views/ReaderView.swift', import.meta.url), 'utf8')
const components = readFileSync(new URL('../PodcastLearning/Views/Components.swift', import.meta.url), 'utf8')
const audio = readFileSync(process.env.PODLEARN_AUDIO_STORE || new URL('../PodcastLearning/Services/AudioStore.swift', import.meta.url), 'utf8')
const start = reader.indexOf('                ScrollView {')
const end = reader.indexOf('            } else { ItemsView', start)
const buttonStart = reader.indexOf('private struct ParagraphPlaybackButton: View')
const buttonEnd = reader.indexOf('struct PlaybackBar: View', buttonStart)
const highlightStart = components.indexOf('struct WavyUnderline: TextAttribute')
const highlightEnd = components.indexOf('struct SettingsIcon: View', highlightStart)
const activeStart = audio.indexOf('    func isActive(')
const activeEnd = audio.indexOf('    func toggleParagraph(', activeStart)
assert.ok(start >= 0 && end > start && highlightStart >= 0 && highlightEnd > highlightStart && activeStart >= 0 && activeEnd > activeStart)
const highlights = components.slice(highlightStart, highlightEnd).replace('private var content: Text {', 'private var content: Text {\n        Counters.highlights += 1')
const dir = mkdtempSync(join(tmpdir(), 'podcast-reader-playback-'))
try {
  const file = join(dir, 'check.swift')
  writeFileSync(file, `import SwiftUI
import AppKit
import NaturalLanguage
import Observation

@MainActor enum Counters { static var highlights = 0; static var itemScans = 0 }
nonisolated final class Flag: @unchecked Sendable { var value = 0 }
struct AccentTheme { var color = Color.purple }
extension EnvironmentValues { @Entry var accentTheme = AccentTheme() }
enum Palette {
    static let accent = Color.purple, onAccent = Color.white, cell = Color.white
    static let key = Color.yellow, list = Color.blue, ai = Color.orange, manual = Color.teal
    static func source(_ source: ItemSource) -> Color { source == .list ? list : source == .ai ? ai : manual }
}
enum ItemSource { case list, ai, manual }
@Observable final class Sentence: Identifiable {
    let id = UUID(); var text = "Scrolling a transcript should stay smooth while the audio keeps playing."; var isKey = false
}
struct DictationItem { var itemSource = ItemSource.list }
struct HighlightMatch { let range: Range<String.Index>; let item: DictationItem }
enum TextMatch { static func highlights(in text: String, items: [DictationItem]) -> [HighlightMatch] { [] } }
@Observable final class Segment: Identifiable {
    let id = UUID(); var index: Int; var speaker: String?; var start: Double?; var end: Double?
    var orderedSentences = [Sentence(), Sentence(), Sentence()]
    init(_ index: Int) { self.index = index; start = Double(index * 30); end = Double((index + 1) * 30) }
}
@Observable final class Transcript {
    let id = UUID(); var orderedSegments = (0..<30).map { Segment($0) }; var items: [DictationItem] = []
    var activeItems: [DictationItem] { Counters.itemScans += 1; return items }
    var practiceItems: [DictationItem] { activeItems }
    var showKeySentences = true
}
@Observable final class SettingsStore {}
@Observable final class ClipPlayer {
    var isPlaying = true; var position: Double = 1; var duration: Double = 0; var transcriptID: UUID?
    var segmentID: UUID?; var activeSegmentID: UUID?; var utterance: String?
${audio.slice(activeStart, activeEnd)}
    func toggleParagraph(_ segment: Segment, transcript: Transcript, settings: SettingsStore) {}
    func isWaitingForAudio(_ transcript: Transcript, settings: SettingsStore) -> Bool { false }
}
enum ReaderSelection { case word(String, Sentence), sentence(Sentence) }
func timestamp(_ seconds: Double) -> String { "00:00" }
// Observation contract: the paragraph play/pause button may depend on playback state,
// but never on the 10 Hz position/duration tick.
let probe = ClipPlayer()
let trackedTranscript = Transcript()
probe.transcriptID = trackedTranscript.id
let trackedSegment = trackedTranscript.orderedSegments[2]
func observeIsActive() -> Flag {
    let flag = Flag()
    withObservationTracking { _ = probe.isActive(trackedSegment, in: trackedTranscript) } onChange: { flag.value += 1 }
    return flag
}
let tickChanges = observeIsActive()
probe.position += 0.1
probe.duration += 1
precondition(tickChanges.value == 0, "Reader rows must not observe the playback position tick")
let playChanges = observeIsActive()
probe.isPlaying.toggle()
precondition(playChanges.value == 1, "Play/pause state must still update the button")
probe.isPlaying = true
let segmentChanges = observeIsActive()
probe.activeSegmentID = trackedSegment.id
precondition(segmentChanges.value == 1, "The active paragraph must still update the button")
precondition(probe.isActive(trackedSegment, in: trackedTranscript), "Active paragraph reads as playing")
precondition(!probe.isActive(trackedTranscript.orderedSegments[3], in: trackedTranscript), "Other paragraphs stay idle")
${highlights}
${buttonStart >= 0 ? reader.slice(buttonStart, buttonEnd) : ''}
struct ReaderScrollProbe: View {
    let transcript: Transcript
    @Environment(ClipPlayer.self) private var player
    @Environment(SettingsStore.self) private var settings
    @Environment(\\.accentTheme) private var theme
    @State private var selection: ReaderSelection?
    var transcriptionStatus: some View { EmptyView() }
    var synthesisStatus: some View { EmptyView() }
    var analysisStatus: some View { EmptyView() }
    var body: some View {
${reader.slice(start, end)}
    }
}
let player = ClipPlayer()
let transcript = Transcript()
player.transcriptID = transcript.id
let renderer = ImageRenderer(content: ReaderScrollProbe(transcript: transcript)
    .environment(player).environment(SettingsStore()).frame(width: 390, height: 800))
renderer.scale = 1
precondition(renderer.cgImage != nil, "Reader must render")
let baseline = Counters.highlights
let initialScans = Counters.itemScans
precondition(baseline > 0, "Real highlight renderer must be exercised")
for tick in 1...30 {
    player.position = 1 + Double(tick) / 10
    RunLoop.current.run(until: Date().addingTimeInterval(0.002))
    precondition(renderer.cgImage != nil, "Reader must keep rendering")
}
let repeated = Counters.highlights - baseline
let repeatedScans = Counters.itemScans - initialScans
print("Sentence renders: initial=\\(baseline), playback-only=\\(repeated); item-list scans=\\(repeatedScans); ticks=30")
precondition(repeated == 0 && repeatedScans == 0, "Playback ticks must not rebuild transcript highlights or scan the word list")
transcript.orderedSegments[0].orderedSentences[0].text += " Changed text."
RunLoop.current.run(until: Date().addingTimeInterval(0.002))
precondition(renderer.cgImage != nil)
precondition(Counters.highlights > baseline, "Transcript edits must still invalidate highlights")
print("PASS: playback ticks isolated from transcript highlights; edits remain observable")
`)
  process.stdout.write(execFileSync('swift', ['-swift-version', '6', '-default-isolation', 'MainActor', file], { encoding: 'utf8' }))
} finally {
  rmSync(dir, { recursive: true, force: true })
}
