import Foundation
import Testing
import AVFoundation
@testable import PodcastCore

@Test func speechChunksPreserveTextAndRespectUnicodeLimits() {
    for text in [String(repeating: "A sentence with words.\n\n", count: 700), String(repeating: "字", count: 10_001),
                 String(repeating: "👨‍👩‍👧‍👦é", count: 1500), "hello", String(repeating: "x", count: 4001)] {
        let chunks = SpeechText.chunks(text)
        #expect(chunks.joined() == text)
        #expect(chunks.allSatisfy { $0.unicodeScalars.count <= 4000 })
        #expect(chunks.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }
    #expect(SpeechText.chunks(" \n\t ").isEmpty)
    let sentences = SpeechText.chunks(String(repeating: "This is a complete sentence. ", count: 300))
    #expect(sentences.dropLast().allSatisfy { $0.hasSuffix(". ") })
}

private final class SpeechStub: @unchecked Sendable {
    let lock = NSLock()
    private var requests: [URLRequest] = []
    var status = 200
    var mime = "audio/mpeg"
    var failInput: String?
    var invalidAudio = false
    private var headers: [String: String] = [:]
    private var delays: [String: Double] = [:]
    private var throttleOnce: String?
    private var active = 0, peak = 0
    private var completed: [String] = []
    private var started: [Date] = []
    struct Reply { let status: Int; let headers: [String: String]; let data: Data; let delay: Double; let input: String }
    func reset(status: Int = 200, mime: String = "audio/mpeg", failInput: String? = nil, invalidAudio: Bool = false,
               headers: [String: String] = [:], delays: [String: Double] = [:], throttleOnce: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        requests = []; self.status = status; self.mime = mime; self.failInput = failInput; self.invalidAudio = invalidAudio
        self.headers = headers; self.delays = delays; self.throttleOnce = throttleOnce
        active = 0; peak = 0; completed = []; started = []
    }
    func response(_ request: URLRequest) -> Reply {
        lock.lock(); defer { lock.unlock() }
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            request.httpBody = data
        }
        requests.append(request)
        let json = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        let input = json?["input"] ?? ""
        let failed = failInput != nil && input == failInput
        let throttled = throttleOnce == input
        if throttled { throttleOnce = nil }
        active += 1; peak = max(peak, active); started.append(Date())
        let fixture = input == "Second paragraph." ? "speech-long-tone" : "speech-tone"
        let data = invalidAudio ? Data("not audio".utf8) : try! Data(contentsOf: Bundle.module.url(forResource: fixture, withExtension: "mp3", subdirectory: "Fixtures")!)
        return Reply(status: throttled ? 429 : failed ? 503 : status, headers: headers.merging(["Content-Type": mime]) { _, new in new },
                     data: data, delay: delays[input] ?? 0, input: input)
    }
    func finish(_ input: String) { lock.lock(); defer { lock.unlock() }; active -= 1; completed.append(input) }
    func snapshot() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    func activity() -> (peak: Int, completed: [String], started: [Date]) { lock.lock(); defer { lock.unlock() }; return (peak, completed, started) }
}
private final class SpeechProtocol: URLProtocol, @unchecked Sendable {
    static let stub = SpeechStub()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private let lock = NSLock()
    private var stopped = false
    private var reply: SpeechStub.Reply?
    override func startLoading() {
        let reply = Self.stub.response(request)
        lock.lock(); self.reply = reply; lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) {
            self.lock.lock()
            guard !self.stopped else { self.lock.unlock(); return }
            self.stopped = true; self.lock.unlock()
            Self.stub.finish(reply.input)
            let response = HTTPURLResponse(url: self.request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: reply.data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {
        lock.lock(); defer { lock.unlock() }
        if !stopped, let reply { stopped = true; Self.stub.finish(reply.input) }
    }
}

private actor ReadyParagraphs {
    var indexes: [Int] = []
    func record(_ index: Int, file: URL, final: URL) throws {
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: final.path), "Each paragraph is playable before the final merge")
        #expect(!(try Data(contentsOf: file)).isEmpty)
        indexes.append(index)
    }
}

@Suite(.serialized) struct SpeechSynthesisTests {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SpeechProtocol.self]
        return URLSession(configuration: config)
    }
    @Test func sendsOpenRouterSpeechRequestAndValidatesAudioBeforeReplacingFiles() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("speech.mp3")
        var client = try SpeechSynthesizer(key: " test-key ", session: session)
        client.limiter = SpeechRateLimiter()
        SpeechProtocol.stub.reset()
        try await client.synthesize("Hello world.", to: file)
        let good = try Data(contentsOf: file)
        let request = try #require(SpeechProtocol.stub.snapshot().first)
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/audio/speech")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == ["model": "elevenlabs/eleven-v4-turbo", "voice": "george", "input": "Hello world.", "response_format": "mp3"])
        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        for (status, mime, invalid) in [(401, "audio/mpeg", false), (429, "application/json", false), (200, "text/html", false), (200, "audio/mpeg", true)] {
            client.limiter = SpeechRateLimiter()
            SpeechProtocol.stub.reset(status: status, mime: mime, invalidAudio: invalid, headers: ["Retry-After": "3601"])
            await #expect(throws: (any Error).self) { try await client.synthesize("Hello", to: file) }
            #expect(try Data(contentsOf: file) == good)
            #expect(SpeechProtocol.stub.snapshot().count == 1)
        }
        await #expect(throws: ImportError.self) { try await client.synthesize("  ", to: file) }
        await #expect(throws: ImportError.self) { try await client.synthesize(String(repeating: "x", count: 10_001), to: file) }
        #expect(throws: ImportError.self) { try SpeechSynthesizer(key: " ") }
        #expect(throws: ImportError.self) { try SpeechSynthesizer(key: "key", voice: " ") }
        #expect(throws: ImportError.self) { try SpeechSynthesizer(key: "key", model: " ") }
    }
    @Test func parallelPiecesPreserveDocumentOrderDespiteOutOfOrderResponses() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var client = try SpeechSynthesizer(key: "key", session: session)
        client.limiter = SpeechRateLimiter()
        SpeechProtocol.stub.reset(delays: ["First paragraph.": 0.3, "Second paragraph.": 0.02, "Third paragraph.": 0.02])
        let ready = ReadyParagraphs(), final = directory.appendingPathComponent("joined.m4a")
        let result = try await client.generate(paragraphs: ["First paragraph.", "Second paragraph.", "Third paragraph."],
            directory: directory, to: final, onParagraphReady: { index, file in try await ready.record(index, file: file, final: final) })
        let readyIndexes = await ready.indexes
        #expect(readyIndexes.count == 3)
        #expect(Set(readyIndexes) == Set([0, 1, 2]))
        let activity = SpeechProtocol.stub.activity()
        #expect(activity.peak >= 2 && activity.peak <= SpeechRateLimiter.maximum)
        #expect(activity.completed.count == 3 && activity.completed.first != "First paragraph.")
        #expect(result.ranges.count == 3)
        #expect(result.ranges[0].start == 0 && result.ranges[1].start == result.ranges[0].end)
        let firstDuration = result.ranges[0].end - result.ranges[0].start
        let secondDuration = result.ranges[1].end - result.ranges[1].start
        #expect(secondDuration > firstDuration + 0.2)
    }
    @Test func simultaneousDocumentsShareOneConcurrencyBudget() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var configured = try SpeechSynthesizer(key: "key", session: session)
        configured.limiter = SpeechRateLimiter()
        let first = configured, second = configured
        let pieces = (0..<16).map { "Piece \($0)." }
        SpeechProtocol.stub.reset(delays: Dictionary(uniqueKeysWithValues: pieces.map { ($0, 0.1) }))
        async let a = first.generate(paragraphs: Array(pieces.prefix(8)), directory: directory.appendingPathComponent("a"), to: directory.appendingPathComponent("a.m4a"))
        async let b = second.generate(paragraphs: Array(pieces.suffix(8)), directory: directory.appendingPathComponent("b"), to: directory.appendingPathComponent("b.m4a"))
        _ = try await (a, b)
        #expect(SpeechProtocol.stub.activity().peak > 1)
        #expect(SpeechProtocol.stub.activity().peak <= SpeechRateLimiter.maximum)
        #expect(SpeechProtocol.stub.snapshot().count == 16)
    }
    @Test func throttlingWaitsAndRetriesAreBounded() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var client = try SpeechSynthesizer(key: "key", session: session)
        client.limiter = SpeechRateLimiter()
        SpeechProtocol.stub.reset(headers: ["Retry-After": "0.15"], throttleOnce: "Hello")
        try await client.synthesize("Hello", to: directory.appendingPathComponent("hello.mp3"))
        let starts = SpeechProtocol.stub.activity().started
        #expect(starts.count == 2 && starts[1].timeIntervalSince(starts[0]) >= 0.14)
        SpeechProtocol.stub.reset(status: 429, headers: ["Retry-After": "0"])
        await #expect(throws: ImportError.self) { try await client.synthesize("Hello", to: directory.appendingPathComponent("hello.mp3")) }
        #expect(SpeechProtocol.stub.snapshot().count == 5)
        #expect(await client.limiter.active == 0)
    }
    @Test func retryReusesCompletedPartsAndCombinesRealAudioWithParagraphTiming() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("joined.m4a"), parts = directory.appendingPathComponent("parts")
        var client = try SpeechSynthesizer(key: "key", session: session)
        client.limiter = SpeechRateLimiter()
        SpeechProtocol.stub.reset()
        _ = try await client.generate(paragraphs: ["First paragraph."], directory: parts, to: file)
        try FileManager.default.removeItem(at: file)
        SpeechProtocol.stub.reset(failInput: "Second paragraph.")
        await #expect(throws: ImportError.self) {
            _ = try await client.generate(paragraphs: ["First paragraph.", "Second paragraph."], directory: parts, to: file)
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: parts.path).count == 1)
        SpeechProtocol.stub.reset()
        let result = try await client.generate(paragraphs: ["First paragraph.", "Second paragraph."], directory: parts, to: file)
        #expect(SpeechProtocol.stub.snapshot().count == 1)
        #expect(result.ranges.count == 2)
        #expect(result.ranges[0].start == 0)
        #expect(result.ranges[1].start == result.ranges[0].end)
        let duration = try await AVURLAsset(url: file).load(.duration).seconds
        #expect(abs(duration - result.duration) < 0.1)
        #expect(duration > 0.4)
        _ = try await client.generate(paragraphs: ["First paragraph.", "Second paragraph."], directory: parts, to: file)
        #expect(SpeechProtocol.stub.snapshot().count == 1)
        _ = try await SpeechSynthesizer(key: "key", voice: "other", session: session)
            .generate(paragraphs: ["First paragraph."], directory: parts, to: file)
        #expect(SpeechProtocol.stub.snapshot().count == 2)
        _ = try await client.generate(paragraphs: [String(repeating: "x", count: 8001)], directory: parts, to: file)
        #expect(SpeechProtocol.stub.snapshot().count == 4) // Identical text parts share one cached response.
    }
}
