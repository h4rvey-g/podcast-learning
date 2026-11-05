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
const progress = read('Sources/PodcastCore/ImportProgress.swift')
const reader = read('PodcastLearning/Views/ReaderView.swift')
assert.ok(reader.indexOf('ImportProgressView(transcript: transcript)') < reader.indexOf('Picker("Content"'), 'Progress stays outside the scroll view and tabs')
assert.ok(read('PodcastLearning/Views/LibraryView.swift').includes('ImportProgressView(transcript: transcript)'))
assert.ok(reader.indexOf('Section("Word Sources")') > reader.indexOf('Menu {'), 'Source controls belong in More')
const dir = mkdtempSync(join(tmpdir(), 'podcast-import-progress-'))
try {
  const file = join(dir, 'check.swift')
  writeFileSync(file, `import SwiftUI
import Observation
${progress}
enum SpeechService { case apple, openRouter }
final class SettingsStore { var speechService = SpeechService.openRouter; var aiConsent = true }
enum AudioStore { static var file: URL?; static func localURL(_ id: UUID) -> URL? { file } }
@Observable final class Transcript {
    let id = UUID(); var synthesisState = "none"; var transcriptionState = "none"; var analysisState = "marked"
    var remoteAudioURL: String?; var sourceURL: String?
}
@Observable final class AppStore {
    let settings = SettingsStore()
    var synthesisProgress: [UUID: Double] = [:]; var transcriptionProgress: [UUID: Double] = [:]
    var downloadProgress: [UUID: Double] = [:]; var analysisProgress: [UUID: Double] = [:]
    var downloading: Set<UUID> = []; var processingPhase: [UUID: String] = [:]
${method}
}
struct AccentTheme { var color = Color.purple }
extension EnvironmentValues { @Entry var accentTheme = AccentTheme() }
${view}
let store = AppStore(), transcript = Transcript(), id = transcript.id
precondition(store.importProgress(transcript) == nil)
transcript.synthesisState = "preparing"; store.processingPhase[id] = "extract"
precondition(store.importProgress(transcript)!.steps.map(\\.id) == ["extract", "clean", "mark", "generate", "join", "analyze"])
precondition(store.importProgress(transcript)!.fraction == 0)
store.processingPhase[id] = "clean"
precondition(store.importProgress(transcript)!.title == "AI cleanup")
precondition(store.importProgress(transcript)!.completed == 1)
precondition(store.importProgress(transcript)!.fraction == 1.0 / 6)
transcript.synthesisState = "pending"; transcript.analysisState = "pending"; store.processingPhase[id] = "generate"
store.synthesisProgress[id] = 0.5; store.analysisProgress[id] = 0.5
precondition(store.importProgress(transcript)!.fraction == 4.0 / 6, "Audio and analysis contribute together")
precondition(store.importProgress(transcript)!.title.contains("AI vocabulary analysis"))
func render(_ size: DynamicTypeSize, _ scheme: ColorScheme) {
    let content = ImportProgressView(transcript: transcript).environment(store).environment(\\.dynamicTypeSize, size).environment(\\.colorScheme, scheme).padding().frame(width: 320)
    let renderer = ImageRenderer(content: content)
    precondition(renderer.cgImage != nil, "Progress must render at small width and accessibility sizes")
}
for size in [DynamicTypeSize.large, .accessibility5] { for scheme in [ColorScheme.light, .dark] { render(size, scheme) } }
store.synthesisProgress[id] = 1; store.processingPhase[id] = "join"
precondition(store.importProgress(transcript)!.fraction < 1, "Generated parts do not mean joining and analysis are complete")
transcript.synthesisState = "done"
precondition(store.importProgress(transcript)!.fraction < 1, "Audio completion must not hide pending analysis")
transcript.analysisState = "aiDone"
precondition(store.importProgress(transcript) == nil)
transcript.synthesisState = "failed"; transcript.analysisState = "pending"
precondition(store.importProgress(transcript) == nil, "Keep retryable failures visible in Library")
transcript.synthesisState = "none"; transcript.analysisState = "marked"; transcript.transcriptionState = "pending"
transcript.sourceURL = "https://example.test/video"; store.processingPhase[id] = "download"; store.downloadProgress[id] = 0.25
precondition(store.importProgress(transcript)!.steps.first!.fraction == 0.25)
store.processingPhase[id] = "upload"; store.transcriptionProgress[id] = 0.75
precondition(store.importProgress(transcript)!.completed == 2)
store.processingPhase[id] = "transcribe"; store.transcriptionProgress[id] = 1
precondition(store.importProgress(transcript)!.completed == 3)
precondition(store.importProgress(transcript)!.fraction < 1)
transcript.transcriptionState = "done"; transcript.analysisState = "pending"
precondition(store.importProgress(transcript)!.completed == 5)
transcript.analysisState = "aiDone"
precondition(store.importProgress(transcript) == nil)
store.settings.speechService = .apple; transcript.sourceURL = nil; transcript.transcriptionState = "none"; transcript.synthesisState = "preparing"; transcript.analysisState = "marked"
precondition(store.importProgress(transcript)!.steps.map(\\.id) == ["extract", "clean", "mark", "analyze"])
print("PASS: all import steps, concurrent audio/analysis, real transfer fractions, failure/completion, source menu, and SwiftUI rendering")
`)
  process.stdout.write(execFileSync('swift', ['-swift-version', '6', '-default-isolation', 'MainActor', file], { encoding: 'utf8' }))
} finally {
  rmSync(dir, { recursive: true, force: true })
}
