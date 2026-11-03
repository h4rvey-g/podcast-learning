import Foundation
import SwiftData
import Observation
import PodcastCore

@MainActor @Observable final class AppStore {
    let context: ModelContext
    let settings: SettingsStore
    let marker: LevelMarker
    var error: String?
    var importing = false
    var downloading: Set<UUID> = []
    var downloadProgress: [UUID: Double] = [:]
    var audioErrors: [UUID: String] = [:]
    private var analyzing: Set<UUID> = []
    init(context: ModelContext, settings: SettingsStore) throws {
        self.context = context; self.settings = settings; marker = try .bundled()
        for transcript in try context.fetch(FetchDescriptor<Transcript>()) where transcript.analysisState == "pending" {
            transcript.analysisState = "aiFailed"
            transcript.analysisError = "Analysis was interrupted. Retry when you are ready."
        }
        try context.save()
    }
    func save() { do { try context.save() } catch { self.error = "Could not save your changes: \(error.localizedDescription)" } }
    func importText(_ text: String, title: String, fileExtension: String = "txt", level: String? = nil) throws -> Transcript {
        let paragraphs = try TextImporter.paragraphs(text, fileExtension: fileExtension)
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let transcript = TextImporter.makeTranscript(title: name.isEmpty ? String(paragraphs[0].prefix(65)) : name, paragraphs: paragraphs)
        transcript.targetLevelOverride = level
        try insert(transcript)
        return transcript
    }
    func podcastPreview(_ input: String) async throws -> Transcript {
        let link = try EpisodeLink(input)
        let response = try await PodTextClient().fetch(link, uid: settings.uid)
        let transcript = try response.transcript()
        transcript.sourceURL = link.url.absoluteString
        return transcript
    }
    func importPodcast(_ input: String, level: String? = nil, preview: Transcript? = nil) async throws -> Transcript {
        let link = try EpisodeLink(input)
        let episodeID = link.episodeID
        if let existing = try context.fetch(FetchDescriptor<Transcript>(predicate: #Predicate { $0.episodeID == episodeID })).first { return existing }
        let transcript: Transcript
        if let preview, preview.episodeID == episodeID, preview.sourceURL == link.url.absoluteString { transcript = preview }
        else { transcript = try await podcastPreview(input) }
        transcript.targetLevelOverride = level
        try insert(transcript)
        Task { await downloadAudio(transcript) }
        return transcript
    }
    private func insert(_ transcript: Transcript) throws {
        context.insert(transcript)
        marker.mark(transcript, target: CEFR(rawValue: transcript.targetLevelOverride ?? "") ?? settings.level)
        do { try context.save() } catch { context.delete(transcript); throw error }
        if settings.aiConsent { Task { await analyze(transcript) } }
    }
    func analyze(_ transcript: Transcript) async {
        guard analyzing.insert(transcript.id).inserted else { return }
        defer { analyzing.remove(transcript.id) }
        transcript.analysisState = "pending"; transcript.analysisError = nil; save()
        do { try await AIAnalyzer(settings: settings).analyze(transcript); transcript.analysisState = "aiDone" }
        catch { transcript.analysisState = "aiFailed"; transcript.analysisError = error.localizedDescription }
        save()
    }
    func downloadAudio(_ transcript: Transcript) async {
        guard downloading.insert(transcript.id).inserted else { return }
        let id = transcript.id
        audioErrors[id] = nil; downloadProgress[id] = nil
        defer { downloading.remove(id); downloadProgress[id] = nil }
        do {
            if transcript.remoteAudioURL == nil {
                guard let source = transcript.sourceURL,
                      let remote = try await AudioResolver.resolve(EpisodeLink(source), title: transcript.title) else {
                    throw ImportError.service("No episode audio was found. You can still use text to speech.")
                }
                transcript.remoteAudioURL = remote.url.absoluteString; transcript.audioDuration = remote.duration; save()
            }
            guard let value = transcript.remoteAudioURL, let url = URL(string: value) else { throw ImportError.invalidURL }
            try await AudioStore.download(url, id: id) { [weak self] fraction in
                Task { @MainActor in
                    guard let self, self.downloading.contains(id) else { return }
                    self.downloadProgress[id] = fraction
                }
            }
        } catch { audioErrors[id] = error.localizedDescription }
    }
    func changeLevel(_ transcript: Transcript, to value: String?) {
        transcript.targetLevelOverride = value
        let target = CEFR(rawValue: value ?? "") ?? settings.level
        // Preserve removed items and manual/AI selections when changing the list threshold.
        for item in transcript.items ?? [] where item.source == "list" && !item.isRemoved {
            if let level = item.level.flatMap(CEFR.init(rawValue:)), level < target {
                context.delete(item)
            }
        }
        transcript.items = (transcript.items ?? []).filter { !$0.isDeleted }
        marker.mark(transcript, target: target); save()
    }
    func addWord(_ word: String, sentence: Sentence, transcript: Transcript, gloss: String?) {
        let key = Lemmatizer.tokens(word).first?.lemma ?? word.lowercased()
        if let existing = transcript.items?.first(where: { $0.key == key || $0.text.lowercased() == word.lowercased() }) {
            existing.isRemoved = false; existing.sentence = sentence; existing.text = word
        } else {
            let item = DictationItem(text: word, key: key, source: .manual, sentence: sentence)
            item.glossZh = gloss; transcript.items = (transcript.items ?? []) + [item]
        }
        save()
    }
    func consumeSharedImports() async {
        guard !importing, let group = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return }
        let directory = container.appendingPathComponent("PendingImports")
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        importing = true; defer { importing = false }
        for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                let pending = try JSONDecoder().decode(PendingImport.self, from: Data(contentsOf: file))
                if (try? EpisodeLink(pending.text)) != nil { _ = try await importPodcast(pending.text) }
                else { _ = try importText(pending.text, title: pending.title, fileExtension: pending.fileExtension) }
                try FileManager.default.removeItem(at: file)
            } catch { self.error = "Shared import was kept for retry: \(error.localizedDescription)" }
        }
    }
}
