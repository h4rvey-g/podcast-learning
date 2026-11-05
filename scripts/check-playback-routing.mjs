// Run the production playback entry points with speech/network spies; no sound or paid calls.
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const source = readFileSync(new URL('../PodcastLearning/Services/AudioStore.swift', import.meta.url), 'utf8')
const method = (start, end) => {
  const from = source.indexOf(start), to = source.indexOf(end, from)
  assert.ok(from >= 0 && to > from)
  return source.slice(from, to)
}
const dir = mkdtempSync(join(tmpdir(), 'podcast-playback-routing-'))
try {
  const file = join(dir, 'check.swift')
  writeFileSync(file, `import Foundation
import AVFoundation
struct PlaybackRange { let start: Double; let end: Double; init?(start: Double, end: Double) { guard start >= 0, end > start else { return nil }; self.start = start; self.end = end } }
enum SpeechService { case apple, openRouter }
final class SettingsStore { var speechService = SpeechService.openRouter; var speechVoice: AVSpeechSynthesisVoice?; var rate = 0.5 }
final class Segment { let id = UUID(); var start: Double?; var end: Double?; var text = "Practice paragraph." }
final class Transcript { let id = UUID(); var synthesisState = "pending" }
enum AudioStore { static var file: URL?; static func localURL(_ id: UUID) -> URL? { file } }
final class SpeechSpy {
    var calls = 0; var isPaused = false
    func speak(_ utterance: AVSpeechUtterance) { calls += 1 }
}
@MainActor final class ClipPlayer {
    var isPlaying = false; var position: Double = 0; var speechProgress: Double = 0
    var segmentID: UUID?; var activeSegmentID: UUID?; var transcriptID: UUID?
    var audioTranscript: Transcript?; var speechTranscript: Transcript?; var error: String?
    let player = AVPlayer(); let speech = SpeechSpy(); var utterance: AVSpeechUtterance?
    var currentURL: URL?; var boundary: Any?; var playbackRequest = UUID(); var seeking = false; var speed: Float = 1
    var generatedCalls = 0; var toggles = 0; var generatedPlayback = false
    func activate() -> Bool { true }
    func stop() { isPlaying = false; transcriptID = nil; activeSegmentID = nil }
    func playGenerated(text: String, transcript: Transcript?, settings: SettingsStore, clip: Bool) { generatedCalls += 1 }
    static func segmentID(at time: Double, in transcript: Transcript) -> UUID? { nil }
    func toggleCurrent() { toggles += 1 }
${method('    func isWaitingForAudio(', '    private func playGenerated(')}
${method('    func toggle(text:', '    // Reads cached state only:')}
${method('    func isActive(', '    private func toggleCurrent(')}
}
let settings = SettingsStore()
let segment = Segment()
for state in ["preparing", "pending", "preparationFailed", "failed"] {
    let transcript = Transcript(); transcript.synthesisState = state
    for entry in 0..<3 {
        let player = ClipPlayer()
        if entry == 0 { player.play(text: segment.text, segment: segment, transcript: transcript, settings: settings) }
        if entry == 1 { player.toggle(text: segment.text, transcript: transcript, settings: settings) }
        if entry == 2 { player.toggleParagraph(segment, transcript: transcript, settings: settings) }
        precondition(player.speech.calls == 0, "OpenRouter must never fall back to Apple: state=\\(state), entry=\\(entry)")
        precondition(player.generatedCalls == 0 && !player.isPlaying, "Pending/failed document audio must wait for generation/retry, not start duplicate paid calls")
        // A second tap must not resume a stale AVPlayer item after a blocked request.
        player.toggle(text: segment.text, transcript: transcript, settings: settings)
        precondition(player.toggles == 0 && player.speech.calls == 0 && player.generatedCalls == 0)
    }
}
let readyPartTranscript = Transcript()
let readyPart = ClipPlayer()
readyPart.toggleParagraph(segment, transcript: readyPartTranscript, settings: settings, readyAudio: URL(fileURLWithPath: "/tmp/ready-part.mp3"))
precondition(readyPart.isPlaying && readyPart.generatedPlayback && readyPart.activeSegmentID == segment.id)
precondition(readyPart.speech.calls == 0 && readyPart.generatedCalls == 0, "Ready paragraphs play immediately without duplicate paid synthesis")
let pending = Transcript()
for paragraph in [false, true] {
    let stale = ClipPlayer()
    stale.transcriptID = pending.id; stale.activeSegmentID = segment.id; stale.isPlaying = true; stale.speech.isPaused = true
    if paragraph { stale.toggleParagraph(segment, transcript: pending, settings: settings) }
    else { stale.toggle(text: segment.text, transcript: pending, settings: settings) }
    precondition(stale.toggles == 0 && stale.speech.calls == 0 && !stale.isPlaying, "Pending OpenRouter audio must not resume previously selected Apple speech")
}
AudioStore.file = URL(fileURLWithPath: "/tmp/podlearn-routing-nonexistent.m4a")
let downloaded = ClipPlayer(); downloaded.play(text: segment.text, transcript: pending, settings: settings, clip: false)
precondition(downloaded.isPlaying && downloaded.generatedCalls == 0 && downloaded.speech.calls == 0, "Existing downloaded audio must remain playable")
AudioStore.file = nil
let ready = Transcript(); ready.synthesisState = "none"
let generated = ClipPlayer(); generated.play(text: "Ready", transcript: ready, settings: settings)
precondition(generated.generatedCalls == 1 && generated.speech.calls == 0)
let word = ClipPlayer(); word.play(text: "word", settings: settings)
precondition(word.generatedCalls == 1 && word.speech.calls == 0, "Word pronunciation must honor OpenRouter")
settings.speechService = .apple
let apple = ClipPlayer(); apple.play(text: "Apple was explicitly selected", transcript: ready, settings: settings)
precondition(apple.speech.calls == 1 && apple.generatedCalls == 0)
print("PASS: document playback waits for OpenRouter; all entry points honor provider selection; no duplicate paid generation")
`)
  process.stdout.write(execFileSync('swift', ['-swift-version', '6', '-default-isolation', 'MainActor', file], { encoding: 'utf8' }))
} finally {
  rmSync(dir, { recursive: true, force: true })
}
