// Exercise production progress selection and render its shared SwiftUI view without providers.
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8')
const store = read('PodcastLearning/Services/AppStore.swift')
const components = read('PodcastLearning/Views/Components.swift')
const method = store.slice(store.indexOf('    func importProgress('), store.indexOf('    func podcastPreview('))
const view = components.slice(components.indexOf('struct ImportProgressView: View'), components.indexOf('struct PrimaryButton: View'))
assert.ok(method.includes('return nil') && view.includes('ProgressView(value: fraction)'))
const reader = read('PodcastLearning/Views/ReaderView.swift')
assert.ok(reader.indexOf('ImportProgressView(transcript: transcript)') < reader.indexOf('Picker("Content"'), 'Progress must stay outside the transcript scroll view and tabs')
assert.ok(read('PodcastLearning/Views/LibraryView.swift').includes('ImportProgressView(transcript: transcript)'))
const dir = mkdtempSync(join(tmpdir(), 'podcast-import-progress-'))
try {
  const file = join(dir, 'check.swift')
  writeFileSync(file, `import SwiftUI
import Observation
@Observable final class Transcript {
    let id = UUID(); var synthesisState = "none"; var transcriptionState = "none"; var analysisState = "marked"; var remoteAudioURL: String?
}
@Observable final class AppStore {
    var synthesisStatus: [UUID: String] = [:]
    var transcriptionStatus: [UUID: String] = [:]
    var synthesisProgress: [UUID: Double] = [:]
    var transcriptionProgress: [UUID: Double] = [:]
    var downloadProgress: [UUID: Double] = [:]
    var downloading: Set<UUID> = []
${method}
}
struct AccentTheme { var color = Color.purple }
extension EnvironmentValues { @Entry var accentTheme = AccentTheme() }
${view}
let store = AppStore(), transcript = Transcript(), id = transcript.id
precondition(store.importProgress(transcript) == nil)
transcript.synthesisState = "preparing"
store.synthesisStatus[id] = "Cleaning and splitting document text with AI…"
precondition(store.importProgress(transcript)?.title == store.synthesisStatus[id])
precondition(store.importProgress(transcript)?.fraction == nil, "AI cleanup has no measurable percentage")
transcript.synthesisState = "pending"; store.synthesisStatus[id] = "Generating AI audio · 2 of 4 parts"; store.synthesisProgress[id] = 0.5
precondition(store.importProgress(transcript)?.fraction == 0.5)
func render(_ size: DynamicTypeSize, _ scheme: ColorScheme) {
    let content = ImportProgressView(transcript: transcript).environment(store).environment(\\.dynamicTypeSize, size).environment(\\.colorScheme, scheme).padding().frame(width: 320)
    let renderer = ImageRenderer(content: content)
    precondition(renderer.cgImage != nil, "Real progress view must render at small width, including accessibility sizes")
}
for size in [DynamicTypeSize.large, .accessibility5] { for scheme in [ColorScheme.light, .dark] { render(size, scheme) } }
store.synthesisProgress[id] = 1; store.synthesisStatus[id] = "Combining AI audio…"
precondition(store.importProgress(transcript)?.fraction == nil, "Joining is not a completed import")
render(.large, .light)
transcript.synthesisState = "done"
precondition(store.importProgress(transcript) == nil)
transcript.synthesisState = "failed"; transcript.analysisState = "pending"
precondition(store.importProgress(transcript) == nil, "Background analysis must not hide a retryable failure in Library")
transcript.synthesisState = "none"; transcript.analysisState = "marked"; transcript.transcriptionState = "pending"
store.transcriptionStatus[id] = "Downloading audio…"; store.downloadProgress[id] = 0.25
precondition(store.importProgress(transcript)?.fraction == 0.25)
store.transcriptionProgress[id] = 0.75; store.transcriptionStatus[id] = "Uploading audio…"
precondition(store.importProgress(transcript)?.fraction == 0.75)
store.transcriptionProgress[id] = 1; store.transcriptionStatus[id] = "Transcribing · Waiting for result…"
precondition(store.importProgress(transcript)?.fraction == nil, "100% uploaded is not 100% transcribed; do not reuse stale download progress")
transcript.transcriptionState = "done"; store.downloading.insert(id); transcript.remoteAudioURL = "https://example.test/audio.mp3"
precondition(store.importProgress(transcript)?.fraction == 0.25)
store.downloading.remove(id)
precondition(store.importProgress(transcript) == nil, "Finished imports must remove the indicator")
print("PASS: URL/text progress stages, measured fractions, indeterminate AI/joining, completion/failure, and SwiftUI rendering")
`)
  process.stdout.write(execFileSync('swift', ['-swift-version', '6', '-default-isolation', 'MainActor', file], { encoding: 'utf8' }))
} finally {
  rmSync(dir, { recursive: true, force: true })
}
