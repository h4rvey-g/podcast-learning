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
    var transcribing: Set<UUID> = []
    var transcriptionProgress: [UUID: Double] = [:]
    var transcriptionStatus: [UUID: String] = [:]
    init(context: ModelContext, settings: SettingsStore) throws {
        self.context = context; self.settings = settings; marker = try .bundled()
        for transcript in try context.fetch(FetchDescriptor<Transcript>()) where transcript.analysisState == "pending" {
            transcript.analysisState = "aiFailed"
            transcript.analysisError = "Analysis was interrupted. Retry when you are ready."
        }
        for transcript in try context.fetch(FetchDescriptor<Transcript>()) where transcript.transcriptionState == "pending" {
            transcript.transcriptionState = "failed"
            transcript.transcriptionError = "Transcription was interrupted. Downloaded audio and completed results are kept. Tap Retry Transcription."
        }
        try context.save()
    }
    func save() { do { try context.save() } catch { self.error = "Could not save your changes: \(error.localizedDescription)" } }
    func removeTranscript(_ transcript: Transcript) throws {
        let id = transcript.id
        context.delete(transcript)
        do { try context.save() }
        catch { context.rollback(); throw error }
        downloading.remove(id); transcribing.remove(id)
        audioErrors[id] = nil; downloadProgress[id] = nil; transcriptionProgress[id] = nil; transcriptionStatus[id] = nil
        // Transfers that finish later clean up again in their defers.
        removeMedia(id)
    }
    private func removeMedia(_ id: UUID) {
        do { try AudioStore.delete(id) }
        catch { self.error = "Transcript removed, but its downloaded media could not be deleted: \(error.localizedDescription)" }
    }
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
    func bilibiliPreview(_ input: String) async throws -> Transcript {
        let media = try await BilibiliClient().resolve(BilibiliLink(input), includeVideo: settings.keepBilibiliVideo)
        let transcript = Transcript(title: media.title, author: media.author)
        transcript.episodeID = media.link.episodeID; transcript.sourceURL = media.link.url.absoluteString
        transcript.coverURL = media.cover; transcript.audioDuration = media.duration
        return transcript
    }
    func importBilibili(_ input: String, level: String? = nil, preview: Transcript? = nil) async throws -> Transcript {
        let link = try await BilibiliClient().expand(BilibiliLink(input)), episodeID = link.episodeID
        if let existing = try context.fetch(FetchDescriptor<Transcript>(predicate: #Predicate { $0.episodeID == episodeID })).first { return existing }
        guard settings.transcriptionConsent else { throw ImportError.service("Enable Audio Transcription in Settings before importing from Bilibili.") }
        _ = try MAITranscriber(endpoint: settings.speechEndpoint, key: APIKey.read(account: "azureSpeech"), model: settings.speechModel)
        let transcript: Transcript
        if let preview, preview.episodeID == episodeID { transcript = preview }
        else { transcript = try await bilibiliPreview(input) }
        if let existing = try context.fetch(FetchDescriptor<Transcript>(predicate: #Predicate { $0.episodeID == episodeID })).first { return existing }
        transcript.targetLevelOverride = level; transcript.keepVideo = settings.keepBilibiliVideo && !link.isAudio
        transcript.transcriptionState = "pending"
        context.insert(transcript)
        do { try context.save() } catch { context.delete(transcript); throw error }
        Task { await transcribe(transcript) }
        return transcript
    }
    func transcribe(_ transcript: Transcript) async {
        guard transcript.modelContext != nil, transcript.orderedSegments.isEmpty, !downloading.contains(transcript.id), transcribing.insert(transcript.id).inserted else { return }
        let id = transcript.id
        downloadProgress[id] = nil; transcriptionProgress[id] = nil
        defer {
            transcribing.remove(id); downloadProgress[id] = nil; transcriptionProgress[id] = nil; transcriptionStatus[id] = nil
            if transcript.modelContext == nil { removeMedia(id) }
        }
        transcript.keepVideo = transcript.keepVideo && settings.keepBilibiliVideo
        transcript.transcriptionState = "pending"; transcript.transcriptionError = nil
        do {
            try context.save()
            guard settings.transcriptionConsent else { throw ImportError.service("Enable Audio Transcription in Settings to retry.") }
            let directory = try AudioStore.workDirectory(id)
            let resultFile = directory.appendingPathComponent("result.json")
            let result: MAIResult
            if FileManager.default.fileExists(atPath: resultFile.path) {
                result = try JSONDecoder().decode(MAIResult.self, from: Data(contentsOf: resultFile))
            } else {
                let client = try MAITranscriber(endpoint: settings.speechEndpoint, key: APIKey.read(account: "azureSpeech"), model: settings.speechModel)
                transcriptionStatus[id] = "Downloading audio…"
                try await downloadBilibili(transcript)
                guard transcript.modelContext != nil else { return }
                let wav = directory.appendingPathComponent("audio.wav")
                downloadProgress[id] = nil
                transcriptionStatus[id] = "Preparing audio…"
                guard let source = AudioStore.localURL(id) else { throw ImportError.invalidResponse }
                try await Task.detached(priority: .utility) { try AudioPreparation.wav(from: source, to: wav) }.value
                guard transcript.modelContext != nil else { return }
                guard settings.transcriptionConsent else { throw ImportError.service("Audio transcription was turned off. Your downloaded audio is kept.") }
                transcriptionStatus[id] = "Uploading audio…"
                result = try await client.transcribe(wav, resultFile: resultFile) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.transcribing.contains(id) else { return }
                        self.transcriptionProgress[id] = fraction
                        self.transcriptionStatus[id] = fraction < 1 ? "Uploading audio…" : "Transcribing · Waiting for result…"
                    }
                }
            }
            guard transcript.modelContext != nil else { return }
            try result.apply(to: transcript)
            marker.mark(transcript, target: CEFR(rawValue: transcript.targetLevelOverride ?? "") ?? settings.level)
            transcript.transcriptionState = "done"
            try context.save()
            // Keep the result until the transcript is durably saved; cleanup never changes success.
            try? FileManager.default.removeItem(at: directory)
            if settings.aiConsent { Task { await analyze(transcript) } }
        } catch {
            guard transcript.modelContext != nil else { return }
            // A failed save must not leave unsaved segments that block applying the cached result.
            if transcript.transcriptionState == "done" {
                for item in transcript.items ?? [] { context.delete(item) }
                for segment in transcript.segments ?? [] { context.delete(segment) }
                transcript.items = []; transcript.segments = []
            }
            transcript.transcriptionState = "failed"; transcript.transcriptionError = error.localizedDescription
            save()
        }
    }
    private func downloadBilibili(_ transcript: Transcript) async throws {
        guard let source = transcript.sourceURL else { throw ImportError.invalidURL }
        let id = transcript.id
        let audioFile = try AudioStore.bilibiliFile(id), videoFile = try AudioStore.videoFile(id)
        let needsAudio = AudioStore.localURL(id) == nil
        let needsVideo = transcript.keepVideo && !FileManager.default.fileExists(atPath: videoFile.path)
        guard needsAudio || needsVideo else { return }
        let media = try await BilibiliClient().resolve(BilibiliLink(source), includeVideo: needsVideo)
        guard transcript.modelContext != nil else { throw CancellationError() }
        let directory = try AudioStore.workDirectory(id)
        if needsAudio {
            try await ReliableTransfer.download(media.audio, to: audioFile, headers: BilibiliClient.headers) { [weak self] fraction in
                Task { @MainActor in
                    guard let self, self.downloading.contains(id) || self.transcribing.contains(id) else { return }
                    self.downloadProgress[id] = fraction
                }
            }
            guard transcript.modelContext != nil else { throw CancellationError() }
        }
        if needsVideo && !media.link.isAudio {
            transcriptionStatus[id] = "Downloading video…"
            let track = directory.appendingPathComponent("video-track.mp4")
            if !FileManager.default.fileExists(atPath: track.path) {
                try await ReliableTransfer.download(media.video, to: track, headers: BilibiliClient.headers)
                guard transcript.modelContext != nil else { throw CancellationError() }
            }
            try await AudioPreparation.video(audio: audioFile, track: track, to: videoFile)
        }
    }
    private func insert(_ transcript: Transcript) throws {
        context.insert(transcript)
        marker.mark(transcript, target: CEFR(rawValue: transcript.targetLevelOverride ?? "") ?? settings.level)
        do { try context.save() } catch { context.delete(transcript); throw error }
        if settings.aiConsent { Task { await analyze(transcript) } }
    }
    func analyze(_ transcript: Transcript) async {
        guard transcript.modelContext != nil, !transcript.orderedSegments.isEmpty, analyzing.insert(transcript.id).inserted else { return }
        let id = transcript.id
        defer { analyzing.remove(id) }
        transcript.analysisState = "pending"; transcript.analysisError = nil; save()
        do {
            try await AIAnalyzer(settings: settings).analyze(transcript)
            guard transcript.modelContext != nil else { return }
            transcript.analysisState = "aiDone"
        } catch {
            guard transcript.modelContext != nil else { return }
            transcript.analysisState = "aiFailed"; transcript.analysisError = error.localizedDescription
        }
        save()
    }
    func downloadAudio(_ transcript: Transcript) async {
        guard transcript.modelContext != nil, !transcribing.contains(transcript.id), downloading.insert(transcript.id).inserted else { return }
        let id = transcript.id
        audioErrors[id] = nil; downloadProgress[id] = nil
        defer {
            downloading.remove(id); downloadProgress[id] = nil
            if transcript.modelContext == nil { removeMedia(id) }
        }
        do {
            if let source = transcript.sourceURL, (try? BilibiliLink(source)) != nil {
                try await downloadBilibili(transcript)
                return
            }
            if transcript.remoteAudioURL == nil {
                guard let source = transcript.sourceURL,
                      let remote = try await AudioResolver.resolve(EpisodeLink(source), title: transcript.title) else {
                    throw ImportError.service("No episode audio was found. You can still use text to speech.")
                }
                guard transcript.modelContext != nil else { return }
                transcript.remoteAudioURL = remote.url.absoluteString; transcript.audioDuration = remote.duration; save()
            }
            guard let value = transcript.remoteAudioURL, let url = URL(string: value) else { throw ImportError.invalidURL }
            try await AudioStore.download(url, id: id) { [weak self] fraction in
                Task { @MainActor in
                    guard let self, self.downloading.contains(id) else { return }
                    self.downloadProgress[id] = fraction
                }
            }
        } catch { if transcript.modelContext != nil { audioErrors[id] = error.localizedDescription } }
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
                if (try? BilibiliLink(pending.text)) != nil { _ = try await importBilibili(pending.text) }
                else if (try? EpisodeLink(pending.text)) != nil { _ = try await importPodcast(pending.text) }
                else { _ = try importText(pending.text, title: pending.title, fileExtension: pending.fileExtension) }
                try FileManager.default.removeItem(at: file)
            } catch { self.error = "Shared import was kept for retry: \(error.localizedDescription)" }
        }
    }
}
