import Foundation
import CryptoKit
import AVFoundation

public enum SpeechText {
    public static func validatePieces(_ pieces: [String]) throws {
        guard !pieces.isEmpty, pieces.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.unicodeScalars.count <= 4000 }) else {
            throw ImportError.service("AI must return nonempty ordered pieces of at most 4,000 characters. Retry with a model that supports JSON schema.")
        }
        guard pieces.reduce(0, { $0 + $1.utf8.count + 2 }) <= 5_000_000 else { throw ImportError.tooLarge }
    }
    // Keep requests below Eleven v4 Turbo's 10,000-character limit, including Unicode scalars.
    public static func chunks(_ text: String, limit: Int = 4000) -> [String] {
        precondition(limit > 0)
        var remaining = text[...], result: [String] = []
        while !remaining.isEmpty {
            let end = remaining.unicodeScalars.index(remaining.startIndex, offsetBy: limit, limitedBy: remaining.endIndex) ?? remaining.endIndex
            let prefix = remaining[..<end]
            let naturalBreak = [prefix.range(of: "\n\n", options: .backwards)?.upperBound,
                                prefix.range(of: ". ", options: .backwards)?.upperBound].compactMap { $0 }.first {
                prefix.unicodeScalars.distance(from: prefix.startIndex, to: $0) >= limit / 2
            }
            let boundary = end == remaining.endIndex ? end : naturalBreak ?? prefix.lastIndex(where: \.isWhitespace).map { remaining.index(after: $0) } ?? end
            let chunk = String(remaining[..<boundary])
            if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(chunk) }
            remaining = remaining[boundary...]
        }
        return result
    }
}

public struct SpeechSynthesizer: Sendable {
    public static let defaultModel = "elevenlabs/eleven-v4-turbo"
    public static let defaultVoice = "george"
    public let model: String
    public let voice: String
    private let key: String
    private let session: URLSession
    var limiter: SpeechRateLimiter = .shared
    public init(key: String, model: String = defaultModel, voice: String = defaultVoice, session: URLSession = .shared) throws {
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.voice = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
        guard !self.key.isEmpty else { throw ImportError.service("Save an OpenRouter key in Speech settings first.") }
        guard !self.model.isEmpty, !self.voice.isEmpty else { throw ImportError.service("Choose a TTS model and a supported voice in Speech settings.") }
    }
    public func synthesize(_ text: String, to destination: URL) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImportError.emptyText }
        guard text.unicodeScalars.count <= 10_000 else { throw ImportError.service("Split speech input into parts of at most 10,000 characters.") }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/audio/speech")!, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "voice": voice, "input": text, "response_format": "mp3"])
        for attempt in 0...4 {
            try await limiter.acquire()
            let data: Data, response: URLResponse
            do { (data, response) = try await session.data(for: request, delegate: SpeechRedirectBlocker()) }
            catch { await limiter.complete(nil); throw error }
            guard let http = response as? HTTPURLResponse else { await limiter.complete(nil); throw ImportError.invalidResponse }
            let mayRetry = await limiter.complete(http, attempt: attempt)
            if http.statusCode == 429 && attempt < 4 && mayRetry { continue }
            guard (200..<300).contains(http.statusCode) else {
                // Provider bodies can echo text or secrets; never surface them in diagnostics.
                throw ImportError.service("Audio generation failed (HTTP \(http.statusCode)). Check your OpenRouter key, credits, model, and voice, then retry. Rate-limited requests retry up to four times; completed parts are kept.")
            }
            guard ["audio/mpeg", "audio/mp3"].contains(http.mimeType?.lowercased() ?? ""), !data.isEmpty else { throw ImportError.invalidResponse }
            try Task.checkCancellation()
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mp3")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try data.write(to: temporary, options: .atomic)
            let duration = try await AVURLAsset(url: temporary).load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw ImportError.invalidResponse }
            try ReliableTransfer.commit(temporary, to: destination)
            return
        }
    }
    public struct Result: Sendable {
        public let ranges: [PlaybackRange]
        public var duration: Double { ranges.last?.end ?? 0 }
    }
    public func generate(paragraphs: [String], directory: URL, to destination: URL,
                         progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> Result {
        let parts = paragraphs.map { SpeechText.chunks($0) }
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty }) else { throw ImportError.emptyText }
        let total = parts.reduce(0) { $0 + $1.count }
        var completed = 0, files: [URL] = [], counts: [Int] = [], jobs: [(URL, String)] = []
        var occurrences: [URL: Int] = [:]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for paragraph in parts {
            counts.append(paragraph.count)
            for text in paragraph {
                try Task.checkCancellation()
                let signature = try JSONEncoder().encode([model, voice, text])
                let hash = SHA256.hash(data: signature).map { String(format: "%02x", $0) }.joined()
                let file = directory.appendingPathComponent(hash + ".mp3")
                files.append(file)
                if FileManager.default.fileExists(atPath: file.path) { completed += 1 }
                else {
                    if occurrences[file] == nil { jobs.append((file, text)) }
                    occurrences[file, default: 0] += 1
                }
            }
        }
        progress(completed, total)
        try await withThrowingTaskGroup(of: URL.self) { group in
            var next = 0
            func enqueue() {
                let (file, text) = jobs[next]; next += 1
                group.addTask { try await synthesize(text, to: file); return file }
            }
            for _ in 0..<min(SpeechRateLimiter.maximum, jobs.count) { enqueue() }
            while let file = try await group.next() {
                completed += occurrences[file] ?? 0; progress(completed, total)
                if next < jobs.count { enqueue() }
            }
        }
        let ranges = try await AudioPreparation.joinAudio(files, to: destination)
        var offset = 0
        let paragraphs = counts.map { count -> PlaybackRange in
            defer { offset += count }
            return PlaybackRange(start: ranges[offset].start, end: ranges[offset + count - 1].end)!
        }
        return Result(ranges: paragraphs)
    }
}

private final class SpeechRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
