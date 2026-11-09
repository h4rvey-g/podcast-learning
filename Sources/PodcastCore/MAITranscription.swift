import Foundation
import Alamofire

public struct MAIResult: Codable, Sendable {
    public let durationMilliseconds: Double
    public let phrases: [Phrase]
    public struct Phrase: Codable, Sendable {
        public let text: String
        public let offsetMilliseconds: Double
        public let durationMilliseconds: Double
        public let speaker: Int?
        public let words: [Word]?
    }
    public struct Word: Codable, Sendable {
        public let text: String
        public let offsetMilliseconds: Double
        public let durationMilliseconds: Double
    }
    public static func load(from file: URL) throws -> MAIResult {
        let data = try Data(contentsOf: file)
        do {
            let result = try JSONDecoder().decode(MAIResult.self, from: data)
            try result.validate()
            return result
        } catch let error as DecodingError {
            throw ImportError.service("Saved transcription result: \(transcriptionDecodingMessage(error)).")
        } catch {
            throw ImportError.service("Saved transcription result: \(error.localizedDescription)")
        }
    }
    public func validate() throws {
        guard durationMilliseconds.isFinite, durationMilliseconds > 0, durationMilliseconds < 7_200_000 else {
            throw ImportError.service("Invalid transcription durationMilliseconds: \(durationMilliseconds); expected 0–7200000 ms (exclusive).")
        }
        guard !phrases.isEmpty else { throw ImportError.service("The transcription result contains no phrases. No speech may have been recognized.") }
        guard phrases.count <= 100_000 else { throw ImportError.service("The transcription result exceeds 100000 phrases.") }
        for (index, phrase) in phrases.enumerated() {
            guard !phrase.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ImportError.service("Empty text in transcription phrase \(index + 1).")
            }
            guard phrase.offsetMilliseconds.isFinite, phrase.durationMilliseconds.isFinite,
                  phrase.offsetMilliseconds >= 0, phrase.durationMilliseconds > 0,
                  phrase.offsetMilliseconds + phrase.durationMilliseconds <= durationMilliseconds + 1000 else {
                throw ImportError.service("Invalid timestamps in transcription phrase \(index + 1): offset \(phrase.offsetMilliseconds) ms, duration \(phrase.durationMilliseconds) ms, audio duration \(durationMilliseconds) ms.")
            }
            for (wordIndex, word) in (phrase.words ?? []).enumerated() {
                guard !word.text.isEmpty else {
                    throw ImportError.service("Empty text in transcription phrase \(index + 1), word \(wordIndex + 1).")
                }
                guard word.offsetMilliseconds.isFinite, word.durationMilliseconds.isFinite,
                      word.offsetMilliseconds >= phrase.offsetMilliseconds, word.durationMilliseconds >= 0,
                      word.offsetMilliseconds + word.durationMilliseconds <= phrase.offsetMilliseconds + phrase.durationMilliseconds + 1000 else {
                    throw ImportError.service("Invalid timestamps in transcription phrase \(index + 1), word \(wordIndex + 1): offset \(word.offsetMilliseconds) ms, duration \(word.durationMilliseconds) ms; phrase range \(phrase.offsetMilliseconds)–\(phrase.offsetMilliseconds + phrase.durationMilliseconds) ms.")
                }
            }
        }
    }
    private var paragraphs: [Phrase] {
        phrases.flatMap { phrase -> [Phrase] in
            guard let words = phrase.words, !words.isEmpty else { return [phrase] }
            var result: [Phrase] = [], group: [Word] = []
            for (index, word) in words.sorted(by: { $0.offsetMilliseconds < $1.offsetMilliseconds }).enumerated() {
                group.append(word)
                let start = group[0].offsetMilliseconds, end = word.offsetMilliseconds + word.durationMilliseconds
                // MAI may return an entire language as one phrase; keep practice clips sentence-sized.
                if word.text.last.map({ ".!?。！？".contains($0) }) == true || end - start >= 30_000 || index == words.count - 1 {
                    result.append(Phrase(text: group.map(\.text).joined(separator: " "), offsetMilliseconds: start,
                                         durationMilliseconds: max(1, end - start), speaker: phrase.speaker, words: nil))
                    group = []
                }
            }
            return result
        }.sorted { $0.offsetMilliseconds < $1.offsetMilliseconds }
    }
    @MainActor public func apply(to transcript: Transcript) throws {
        try validate()
        // Only apply to a pending import; never replace a transcript with existing learning history.
        guard transcript.orderedSegments.isEmpty else { throw ImportError.service("This transcript already has text.") }
        var index = 0
        transcript.segments = paragraphs.enumerated().map { offset, phrase in
            let segment = Segment(index: offset, text: phrase.text, speaker: phrase.speaker.map { "Speaker \($0 + 1)" },
                                  start: phrase.offsetMilliseconds / 1000,
                                  end: (phrase.offsetMilliseconds + phrase.durationMilliseconds) / 1000)
            segment.sentences = TextImporter.sentences(phrase.text).map { text in
                defer { index += 1 }; return Sentence(index: index, text: text)
            }
            return segment
        }
        transcript.audioDuration = durationMilliseconds / 1000
    }
}

public struct MAITranscriber {
    public let endpoint: URL
    public let isOpenRouter: Bool
    private let model: String
    private let key: String
    private let session: Session
    public init(endpoint: String, key: String, model: String = "MAI-Transcribe-2", session: Session = ReliableTransfer.session) throws {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https",
              let host = url.host?.lowercased(), url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { throw ImportError.invalidURL }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        isOpenRouter = host == "openrouter.ai"
        if isOpenRouter {
            guard path == "api/v1", !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ImportError.service("Use https://openrouter.ai/api/v1 and a speech model such as microsoft/mai-transcribe-2.")
            }
            self.endpoint = URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!
            self.model = model == "MAI-Transcribe-2" ? "microsoft/mai-transcribe-2" : model
        } else {
            guard (host.hasSuffix(".cognitiveservices.azure.com") || host.hasSuffix(".services.ai.azure.com")), path.isEmpty else {
                throw ImportError.service("Use your Azure Speech resource root URL or https://openrouter.ai/api/v1.")
            }
            self.endpoint = url.appendingPathComponent("speechtotext/transcriptions:transcribe").appending(queryItems: [URLQueryItem(name: "api-version", value: "2025-10-15")])
            self.model = "MAI-Transcribe-2"
        }
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImportError.service("Save your speech provider key in Settings first.") }
        self.key = key; self.session = session
    }
    public func transcribe(_ audio: URL, resultFile: URL,
                           progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> MAIResult {
        if FileManager.default.fileExists(atPath: resultFile.path) { return try MAIResult.load(from: resultFile) }
        guard audio.pathExtension.lowercased() == "wav" else { throw ImportError.service("Prepare WAV audio before transcription.") }
        let size = try audio.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 44, size < 250_000_000 else { throw ImportError.service("Use audio smaller than 250 MB and shorter than two hours.") }
        let result: MAIResult
        if isOpenRouter {
            let prefix = resultFile.deletingPathExtension()
            let chunks = try await Task.detached(priority: .utility) { try AudioPreparation.chunks(from: audio, prefix: prefix) }.value
            let duration = chunks.reduce(0) { $0 + $1.duration }
            var phrases: [MAIResult.Phrase] = []
            for (index, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                let checkpoint = prefix.appendingPathExtension("part-\(index).json")
                let part: MAIResult
                do {
                    if FileManager.default.fileExists(atPath: checkpoint.path) { part = try MAIResult.load(from: checkpoint) }
                    else {
                        part = try await upload(chunk.file, duration: chunk.duration, progress: { fraction in
                            progress((chunk.offset + fraction * chunk.duration) / duration)
                        })
                        try persist(part, to: checkpoint)
                    }
                    guard part.durationMilliseconds <= chunk.duration * 1000 + 1000 else {
                        throw ImportError.service("Saved part duration \(part.durationMilliseconds) ms exceeds audio part duration \(chunk.duration * 1000) ms.")
                    }
                } catch {
                    if error is CancellationError { throw error }
                    throw ImportError.service("OpenRouter part \(index + 1)/\(chunks.count): \(error.localizedDescription)")
                }
                let offset = chunk.offset * 1000
                phrases += part.phrases.map { phrase in
                    MAIResult.Phrase(text: phrase.text, offsetMilliseconds: phrase.offsetMilliseconds + offset,
                        durationMilliseconds: phrase.durationMilliseconds, speaker: phrase.speaker,
                        words: phrase.words?.map { MAIResult.Word(text: $0.text, offsetMilliseconds: $0.offsetMilliseconds + offset, durationMilliseconds: $0.durationMilliseconds) })
                }
                progress((chunk.offset + chunk.duration) / duration)
            }
            result = MAIResult(durationMilliseconds: duration * 1000, phrases: phrases)
        } else {
            result = try await upload(audio, progress: progress)
        }
        try persist(result, to: resultFile)
        return result
    }
    private func upload(_ audio: URL, duration: Double? = nil,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> MAIResult {
        if isOpenRouter {
            guard (try audio.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 25_000_000 else {
                throw ImportError.service("OpenRouter transcription audio part exceeds the 25 MB upload limit.")
            }
        }
        let definition = Data(#"{"enhancedMode":{"enabled":true,"model":"MAI-Transcribe-2","modelOptions":{"timestamps":"word","transcribeStyle":"verbatim"}}}"#.utf8)
        let router = isOpenRouter, model = model
        let headers: HTTPHeaders = router ? ["Authorization": "Bearer " + key] : ["Ocp-Apim-Subscription-Key": key]
        let request = session.upload(multipartFormData: { form in
            form.append(audio, withName: router ? "file" : "audio", fileName: "audio.wav", mimeType: "audio/wav")
            if router {
                form.append(Data(model.utf8), withName: "model")
                form.append(Data("verbose_json".utf8), withName: "response_format")
                for value in ["segment", "word"] { form.append(Data(value.utf8), withName: "timestamp_granularities[]") }
            } else { form.append(definition, withName: "definition", mimeType: "application/json") }
        }, to: endpoint, usingThreshold: 0, headers: headers)
            .redirect(using: Redirector(behavior: .doNotFollow))
            .validate(statusCode: 200..<300).uploadProgress { progress($0.fractionCompleted) }
        let response = await request.serializingData(emptyResponseCodes: []).response
        try Task.checkCancellation()
        let provider = router ? "OpenRouter" : "Azure Speech"
        let status = response.response?.statusCode
        let mime = response.response?.mimeType ?? ""
        let format = ["application/json", "application/problem+json", "text/html", "text/plain"].contains(mime) ? mime : "other/unknown content type"
        let context = "\(provider) transcription (HTTP \(status.map(String.init) ?? "unavailable"), \(format), \(response.data?.count ?? 0) bytes)"
        if let status, !(200..<300).contains(status) {
            let hint: String
            switch status {
            case 401, 403: hint = "Check the saved Speech API key and its access to the selected speech model/resource (separate from the text AI key)."
            case 404: hint = "Check the speech endpoint and model availability."
            case 413: hint = "The speech provider rejected the audio upload size."
            case 429: hint = "The speech provider's rate limit or quota was reached. Retry later or check billing."
            case 500...599: hint = "The speech provider is unavailable or failed. Try again later."
            default: hint = "The speech provider rejected the request. Check the speech model, audio format, and timestamp support."
            }
            throw ImportError.service("\(context): \(hint)")
        }
        if let error = response.error {
            if case .responseSerializationFailed(reason: .inputDataNilOrZeroLength) = error {
                throw ImportError.service("\(context): empty response body; expected a timed JSON transcript.")
            }
            let code = (error.underlyingError as? URLError)?.code.rawValue
            throw ImportError.service("\(context): upload/response transfer failed\(code.map { " (network code \($0))" } ?? ""). Check your connection and retry; downloaded audio and completed results are kept.")
        }
        let data = try response.result.get()
        guard data.count <= 25_000_000 else { throw ImportError.service("\(context): transcription response exceeds 25 MB.") }
        do {
            let result: MAIResult
            if let duration { result = try JSONDecoder().decode(RouterResult.self, from: data).normalized(duration: duration) }
            else { result = try JSONDecoder().decode(MAIResult.self, from: data) }
            try result.validate()
            return result
        } catch let error as DecodingError {
            throw ImportError.service("\(context): \(transcriptionDecodingMessage(error)); expected a timed JSON transcript.")
        } catch {
            throw ImportError.service("\(context): \(error.localizedDescription)")
        }
    }
    private func persist(_ result: MAIResult, to file: URL) throws {
        try result.validate()
        try JSONEncoder().encode(result).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var url = file, values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    private struct RouterResult: Decodable {
        let text: String
        let segments: [Segment]?
        let words: [Word]?
        struct Segment: Decodable { let text: String; let start: Double; let end: Double; let speaker: Int? }
        struct Word: Decodable { let word: String; let start: Double; let end: Double }
        func normalized(duration: Double) throws -> MAIResult {
            let phrases: [MAIResult.Phrase]
            if let segments, !segments.isEmpty {
                phrases = segments.map { segment in
                    let timedWords = words?.filter { $0.start >= segment.start && $0.end <= segment.end + 0.001 }.map {
                        MAIResult.Word(text: $0.word, offsetMilliseconds: $0.start * 1000, durationMilliseconds: ($0.end - $0.start) * 1000)
                    }
                    return MAIResult.Phrase(text: segment.text, offsetMilliseconds: segment.start * 1000,
                        durationMilliseconds: (segment.end - segment.start) * 1000, speaker: segment.speaker,
                        words: timedWords?.isEmpty == false ? timedWords : nil)
                }
            } else if let words, !words.isEmpty {
                phrases = [MAIResult.Phrase(text: text, offsetMilliseconds: 0, durationMilliseconds: duration * 1000, speaker: nil,
                    words: words.map { MAIResult.Word(text: $0.word, offsetMilliseconds: $0.start * 1000, durationMilliseconds: ($0.end - $0.start) * 1000) })]
            } else { throw ImportError.service("The speech provider returned no timestamps. Choose a model supporting verbose_json timestamps.") }
            return MAIResult(durationMilliseconds: duration * 1000, phrases: phrases)
        }
    }
}

private func transcriptionDecodingMessage(_ error: DecodingError) -> String {
    func path(_ context: DecodingError.Context) -> String {
        let value = context.codingPath.map { $0.stringValue }.joined(separator: ".")
        return value.isEmpty ? "root" : value
    }
    // Decoder debug descriptions can contain response text; report only typed field paths.
    switch error {
    case .keyNotFound(let key, let context):
        let field = context.codingPath.isEmpty ? key.stringValue : "\(path(context)).\(key.stringValue)"
        return "missing field \(field)"
    case .typeMismatch(_, let context): return "wrong type at \(path(context))"
    case .valueNotFound(_, let context): return "null value at \(path(context))"
    case .dataCorrupted(let context): return "invalid JSON or invalid field value at \(path(context))"
    @unknown default: return "invalid JSON transcript"
    }
}
