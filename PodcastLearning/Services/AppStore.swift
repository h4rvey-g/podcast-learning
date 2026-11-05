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
    var synthesizing: Set<UUID> = []
    var synthesisProgress: [UUID: Double] = [:]
    var synthesisStatus: [UUID: String] = [:]
    var cleanupPreview: [UUID: [String]] = [:]
    var paragraphAudio: [UUID: URL] = [:]
    var analysisProgress: [UUID: Double] = [:]
    var processingPhase: [UUID: String] = [:]
    @ObservationIgnored private var synthesisTasks: [UUID: Task<Void, Never>] = [:]
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
        for transcript in try context.fetch(FetchDescriptor<Transcript>()) where ["preparing", "pending"].contains(transcript.synthesisState) {
            if transcript.synthesisState == "preparing" {
                transcript.synthesisState = "preparationFailed"
                transcript.synthesisError = "Document processing was interrupted. The original file is kept. Tap Retry Document Processing."
            } else {
                transcript.synthesisState = "failed"
                transcript.synthesisError = "Audio generation was interrupted. Completed parts are kept. Tap Retry Audio Generation."
            }
        }
        // Audio parts may have been playing when the final file was saved in the previous run.
        for transcript in try context.fetch(FetchDescriptor<Transcript>()) where transcript.synthesisState == "done" {
            if let directory = try? AudioStore.workDirectory(transcript.id) { try? FileManager.default.removeItem(at: directory) }
        }
        try context.save()
    }
    func save() { do { try context.save() } catch { self.error = "Could not save your changes: \(error.localizedDescription)" } }
    func removeTranscript(_ transcript: Transcript) throws {
        let id = transcript.id
        for segment in transcript.orderedSegments { paragraphAudio[segment.id] = nil }
        cleanupPreview[id] = nil; analysisProgress[id] = nil; processingPhase[id] = nil
        context.delete(transcript)
        do { try context.save() }
        catch { context.rollback(); throw error }
        synthesisTasks.removeValue(forKey: id)?.cancel()
        downloading.remove(id); transcribing.remove(id); synthesizing.remove(id); synthesisProgress[id] = nil; synthesisStatus[id] = nil
        audioErrors[id] = nil; downloadProgress[id] = nil; transcriptionProgress[id] = nil; transcriptionStatus[id] = nil; processingPhase[id] = nil
        // Transfers that finish later clean up again in their defers.
        removeMedia(id)
    }
    private func removeMedia(_ id: UUID) {
        do { try AudioStore.delete(id) }
        catch { self.error = "Transcript removed, but its downloaded media could not be deleted: \(error.localizedDescription)" }
    }
    func importText(_ text: String, title: String, fileExtension: String = "txt", level: String? = nil) throws -> Transcript {
        try importSession(DocumentTextImporter.session(text: text, title: title, fileExtension: fileExtension, level: level))
    }
    func importDocument(_ url: URL, level: String? = nil) throws -> Transcript {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return try importSession(DocumentTextImporter.session(from: url, level: level))
    }
    private func importSession(_ transcript: Transcript) throws -> Transcript {
        context.insert(transcript)
        do { try context.save() }
        catch { context.delete(transcript); try? AudioStore.delete(transcript.id); throw error }
        synthesize(transcript)
        return transcript
    }
    private func speechSynthesizer() throws -> SpeechSynthesizer {
        try SpeechSynthesizer(key: APIKey.read(account: "openRouterTTS"), model: settings.ttsModel, voice: settings.ttsVoice)
    }
    func synthesize(_ transcript: Transcript) {
        let id = transcript.id
        guard synthesisTasks[id] == nil else { return }
        synthesisTasks[id] = Task {
            await runSynthesis(transcript)
            synthesisTasks[id] = nil
        }
    }
    private func runSynthesis(_ transcript: Transcript) async {
        let prepareDocument = ["preparing", "preparationFailed"].contains(transcript.synthesisState)
        guard transcript.modelContext != nil, transcript.sourceURL == nil, transcript.remoteAudioURL == nil,
              prepareDocument || !transcript.orderedSegments.isEmpty, synthesizing.insert(transcript.id).inserted else { return }
        let id = transcript.id
        defer {
            synthesizing.remove(id); synthesisProgress[id] = nil; synthesisStatus[id] = nil; cleanupPreview[id] = nil; processingPhase[id] = nil
            if transcript.modelContext == nil { removeMedia(id) }
        }
        transcript.synthesisState = prepareDocument ? "preparing" : "pending"; transcript.synthesisError = nil
        for segment in transcript.orderedSegments { paragraphAudio[segment.id] = nil }
        do {
            try context.save()
            let service = settings.speechService
            let client = service == .openRouter ? try speechSynthesizer() : nil
            let directory = try AudioStore.workDirectory(id)
            if prepareDocument {
                processingPhase[id] = "extract"
                synthesisStatus[id] = "Extracting document text…"
                let source = try DocumentTextImporter.sourceFile(id)
                let extraction = Task.detached(priority: .userInitiated) { try DocumentTextImporter.extract(from: source) }
                let text = try await withTaskCancellationHandler { try await extraction.value } onCancel: { extraction.cancel() }
                try Task.checkCancellation()
                guard transcript.modelContext != nil else { return }
                synthesisStatus[id] = "Cleaning and splitting document text with AI…"
                processingPhase[id] = "clean"; cleanupPreview[id] = []
                let cleaned = try await AIAnalyzer(settings: settings).cleanText(text) { [weak self] piece in
                    guard let self, transcript.modelContext != nil else { throw CancellationError() }
                    self.cleanupPreview[id, default: []].append(piece)
                    self.synthesisStatus[id] = "Cleaning text · \(self.cleanupPreview[id]?.count ?? 0) paragraphs ready"
                }
                try Task.checkCancellation()
                guard transcript.modelContext != nil else { return }
                try DocumentTextImporter.applyCleanedPieces(cleaned, to: transcript)
                cleanupPreview[id] = nil; processingPhase[id] = "mark"
                marker.mark(transcript, target: CEFR(rawValue: transcript.targetLevelOverride ?? "") ?? settings.level)
                try context.save()
                synthesisProgress[id] = nil; synthesisStatus[id] = nil
                if settings.aiConsent { transcript.analysisState = "pending"; Task { await analyze(transcript) } }
            }
            guard let client else {
                transcript.synthesisState = "none"
                try context.save()
                if let source = try? DocumentTextImporter.sourceFile(id) { try? FileManager.default.removeItem(at: source) }
                return
            }
            let segments = transcript.orderedSegments
            processingPhase[id] = "generate"
            let publish: @MainActor @Sendable (Int, URL) throws -> Void = { [weak self] index, file in
                guard let self, transcript.modelContext != nil else { throw CancellationError() }
                self.paragraphAudio[segments[index].id] = file
            }
            let result = try await client.generate(paragraphs: segments.map(\.text), directory: directory, to: AudioStore.bilibiliFile(id),
                onParagraphReady: { index, file in try await publish(index, file) }) { [weak self] completed, total in
                Task { @MainActor in
                    guard let self, self.synthesizing.contains(id) else { return }
                    self.synthesisProgress[id] = Double(completed) / Double(total)
                    self.processingPhase[id] = completed == total ? "join" : "generate"
                    self.synthesisStatus[id] = completed == total ? "Combining AI audio…" : "Generating AI audio · \(completed) of \(total) parts"
                }
            }
            guard transcript.modelContext != nil else { return }
            for (segment, range) in zip(segments, result.ranges) { segment.start = range.start; segment.end = range.end }
            transcript.audioDuration = result.duration; transcript.synthesisState = "done"
            try context.save()
            // Keep playable parts until next launch; a paragraph may still be playing during the merge.
            if let source = try? DocumentTextImporter.sourceFile(id) { try? FileManager.default.removeItem(at: source) }
        } catch {
            guard transcript.modelContext != nil else { return }
            transcript.synthesisState = transcript.synthesisState == "preparing" ? "preparationFailed" : "failed"
            transcript.synthesisError = error.localizedDescription
            save()
        }
    }
    func importProgress(_ transcript: Transcript) -> ImportProgress? {
        let id = transcript.id, phase = processingPhase[id]
        let preparing = transcript.synthesisState == "preparing", generating = transcript.synthesisState == "pending"
        let transcribing = transcript.transcriptionState == "pending", analyzing = transcript.analysisState == "pending"
        guard preparing || generating || transcribing || analyzing || downloading.contains(id) else { return nil }
        if transcript.transcriptionState == "failed" || ["failed", "preparationFailed"].contains(transcript.synthesisState) { return nil }
        var steps: [ImportProgress.Step] = []
        let document = transcript.sourceURL == nil && transcript.remoteAudioURL == nil
        if document {
            steps.append(.init("extract", "Extract text", preparing && phase != "clean" ? .running : .done))
            steps.append(.init("clean", "AI cleanup", preparing ? (phase == "clean" ? .running : .waiting) : .done))
            steps.append(.init("mark", "Mark vocabulary", preparing ? .waiting : .done))
            if settings.speechService == .openRouter || generating || transcript.synthesisState == "done" {
                let joined = transcript.synthesisState == "done"
                let allParts = phase == "join" || joined
                steps.append(.init("generate", "Generate audio", allParts ? .done : generating ? .running : .waiting, fraction: synthesisProgress[id]))
                steps.append(.init("join", "Combine audio", joined ? .done : phase == "join" ? .running : .waiting))
            }
        } else if transcribing || transcript.transcriptionState == "done" {
            let done = transcript.transcriptionState == "done"
            let position = ["download", "prepare", "upload", "transcribe"].firstIndex(of: phase ?? "download") ?? 0
            let titles = ["Download audio", "Prepare audio", "Upload audio", "Transcribe audio"]
            for (index, key) in ["download", "prepare", "upload", "transcribe"].enumerated() {
                steps.append(.init(key, titles[index], done || index < position ? .done : index == position ? .running : .waiting,
                    fraction: key == "download" ? downloadProgress[id] : key == "upload" ? transcriptionProgress[id] : nil))
            }
            steps.append(.init("mark", "Mark vocabulary", done ? .done : .waiting))
        } else if downloading.contains(id) || AudioStore.localURL(id) != nil {
            steps.append(.init("download", "Download audio", downloading.contains(id) ? .running : .done, fraction: downloadProgress[id]))
        }
        if settings.aiConsent || analyzing || transcript.analysisState == "aiDone" {
            steps.append(.init("analyze", "AI vocabulary analysis", transcript.analysisState == "aiDone" ? .done : transcript.analysisState == "aiFailed" ? .failed : analyzing ? .running : .waiting, fraction: analysisProgress[id]))
        }
        return ImportProgress(steps: steps)
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
            transcribing.remove(id); downloadProgress[id] = nil; transcriptionProgress[id] = nil; transcriptionStatus[id] = nil; processingPhase[id] = nil
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
                processingPhase[id] = "download"
                transcriptionStatus[id] = "Downloading audio…"
                try await downloadBilibili(transcript)
                guard transcript.modelContext != nil else { return }
                let wav = directory.appendingPathComponent("audio.wav")
                downloadProgress[id] = nil
                processingPhase[id] = "prepare"
                transcriptionStatus[id] = "Preparing audio…"
                guard let source = AudioStore.localURL(id) else { throw ImportError.invalidResponse }
                try await Task.detached(priority: .utility) { try AudioPreparation.wav(from: source, to: wav) }.value
                guard transcript.modelContext != nil else { return }
                guard settings.transcriptionConsent else { throw ImportError.service("Audio transcription was turned off. Your downloaded audio is kept.") }
                processingPhase[id] = "upload"
                transcriptionStatus[id] = "Uploading audio…"
                result = try await client.transcribe(wav, resultFile: resultFile) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.transcribing.contains(id) else { return }
                        self.processingPhase[id] = fraction < 1 ? "upload" : "transcribe"
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
            if settings.aiConsent { transcript.analysisState = "pending"; Task { await analyze(transcript) } }
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
        if settings.aiConsent { transcript.analysisState = "pending"; Task { await analyze(transcript) } }
    }
    func analyze(_ transcript: Transcript) async {
        guard transcript.modelContext != nil, !transcript.orderedSegments.isEmpty, analyzing.insert(transcript.id).inserted else { return }
        let id = transcript.id
        defer { analyzing.remove(id); analysisProgress[id] = nil }
        transcript.analysisState = "pending"; transcript.analysisError = nil; save()
        do {
            try await AIAnalyzer(settings: settings).analyze(transcript) { [weak self] completed, total in
                guard let self, transcript.modelContext != nil else { throw CancellationError() }
                self.analysisProgress[id] = total > 0 ? Double(completed) / Double(total) : 0
                try self.context.save()
            }
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
        guard !importing, let group = PendingImport.appGroupIdentifier(in: Bundle.main),
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
