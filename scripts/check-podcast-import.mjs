// Run the production podcast import methods with an in-memory store and provider doubles.
import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const read = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8')
const store = read('PodcastLearning/Services/AppStore.swift')
const methods = store.slice(store.indexOf('    func podcastPreview('), store.indexOf('    func bilibiliPreview('))
const core = read('Sources/PodcastCore/PodcastImport.swift')
const link = core.slice(core.indexOf('public struct EpisodeLink'), core.indexOf('public struct PodTextResponse'))
const settings = read('PodcastLearning/Services/SettingsStore.swift')
const mode = settings.slice(settings.indexOf('enum PodcastTranscription:'), settings.indexOf('enum APIKey {'))
const dir = mkdtempSync(join(tmpdir(), 'podcast-import-check-'))
try {
  const file = join(dir, 'check.swift')
  writeFileSync(file, `import Foundation
${link}
${mode}
enum ImportError: Error { case invalidURL, service(String) }
final class Transcript {
    var episodeID: String?; var sourceURL: String?; var targetLevelOverride: String?
    var orderedSegments: [String] = []; var transcriptionState = "none"
}
struct FetchDescriptor<T> { let predicate: Predicate<T> }
final class Context {
    var saved: [Transcript] = []; var failSave = false
    func fetch(_ descriptor: FetchDescriptor<Transcript>) throws -> [Transcript] { try saved.filter { try descriptor.predicate.evaluate($0) } }
    func insert(_ value: Transcript) { saved.append(value) }
    func delete(_ value: Transcript) { saved.removeAll { $0 === value } }
    func save() throws { if failSave { throw ImportError.service("Save failed") } }
}
final class SettingsStore { var podcastTranscription = PodcastTranscription.podText; var transcriptionConsent = false; var speechEndpoint = "test"; var speechModel = "test"; let uid = "test" }
enum APIKey { static var key = "test-key"; static func read(account: String) throws -> String { key } }
struct MAITranscriber { init(endpoint: String, key: String, model: String) throws { if key.isEmpty { throw ImportError.service("Missing key") } } }
func makePreview(_ link: EpisodeLink, text: Bool) -> Transcript {
    let transcript = Transcript(); transcript.episodeID = link.episodeID; transcript.sourceURL = link.url.absoluteString
    transcript.orderedSegments = text ? ["Published transcript"] : []; return transcript
}
@MainActor enum AudioResolver {
    static var calls = 0
    static func preview(_ link: EpisodeLink) async throws -> Transcript { calls += 1; return makePreview(link, text: false) }
}
@MainActor struct PodTextClient {
    static var calls = 0
    func fetch(_ link: EpisodeLink, uid: String) async throws -> Response { Self.calls += 1; return Response(link: link) }
    struct Response { let link: EpisodeLink; func transcript() throws -> Transcript { makePreview(link, text: true) } }
}
@MainActor final class AppStore {
    let context = Context(), settings = SettingsStore()
    var transcribeCalls = 0, downloadCalls = 0
    func insert(_ transcript: Transcript) throws { context.insert(transcript); try context.save() }
    func transcribe(_ transcript: Transcript) async { transcribeCalls += 1 }
    func downloadAudio(_ transcript: Transcript) async { downloadCalls += 1 }
${methods}
}
let input = "https://podcasts.apple.com/us/podcast/a-show/id1200361736?i=1000799212333"
let episode = try EpisodeLink(input)
let stt = await MainActor.run { AppStore() }
await MainActor.run { stt.settings.podcastTranscription = .stt }
do { _ = try await stt.importPodcast(input); preconditionFailure("Consent must be required") } catch {}
await MainActor.run { precondition(stt.context.saved.isEmpty && AudioResolver.calls == 0 && PodTextClient.calls == 0); stt.settings.transcriptionConsent = true; APIKey.key = "" }
do { _ = try await stt.importPodcast(input); preconditionFailure("A saved speech key must be required") } catch {}
await MainActor.run { precondition(stt.context.saved.isEmpty); APIKey.key = "test-key" }
let stalePodTextPreview = makePreview(episode, text: true)
let imported = try await stt.importPodcast(input, level: "C1", preview: stalePodTextPreview)
await Task.yield()
await MainActor.run {
    precondition(imported !== stalePodTextPreview && imported.orderedSegments.isEmpty && imported.transcriptionState == "pending")
    precondition(imported.targetLevelOverride == "C1" && stt.context.saved.count == 1)
    precondition(AudioResolver.calls == 1 && PodTextClient.calls == 0, "STT must completely bypass PodText")
    precondition(stt.transcribeCalls == 1 && stt.downloadCalls == 0)
}
let duplicate = try await stt.importPodcast(input)
await Task.yield()
await MainActor.run { precondition(duplicate === imported && stt.context.saved.count == 1 && stt.transcribeCalls == 1 && AudioResolver.calls == 1) }
let podText = await MainActor.run { AppStore() }
let staleSTTPreview = makePreview(episode, text: false)
let published = try await podText.importPodcast(input, preview: staleSTTPreview)
await Task.yield()
await MainActor.run {
    precondition(!published.orderedSegments.isEmpty && published.transcriptionState == "none")
    precondition(PodTextClient.calls == 1 && AudioResolver.calls == 1)
    precondition(podText.downloadCalls == 1 && podText.transcribeCalls == 0, "PodText must keep its existing import path")
}
let failed = await MainActor.run { AppStore() }
await MainActor.run { failed.settings.podcastTranscription = .stt; failed.settings.transcriptionConsent = true; failed.context.failSave = true }
do { _ = try await failed.importPodcast(input); preconditionFailure("Save failures must propagate") } catch {}
await Task.yield()
await MainActor.run { precondition(failed.context.saved.isEmpty && failed.transcribeCalls == 0, "A failed save must not start a billable transcription") }
print("PASS: podcast provider routing, consent/key validation, stale previews, duplicate imports, and failed-save rollback")
`)
  process.stdout.write(execFileSync('swift', [file], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }))
} finally {
  rmSync(dir, { recursive: true, force: true })
}
