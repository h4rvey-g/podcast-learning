import Foundation
import Testing
import AVFoundation
import Alamofire
@testable import PodcastCore

private let maiJSON = #"{"durationMilliseconds":3000,"phrases":[{"text":"Hello world.","offsetMilliseconds":500,"durationMilliseconds":1500,"speaker":0}]}"#

@Test func bilibiliLinksValidateIdentityAndParts() throws {
    let audio = try BilibiliLink("https://www.bilibili.com/audio/au777180?from=share")
    #expect(audio.isAudio && audio.episodeID == "bilibili:au777180:1")
    #expect(audio.url.absoluteString == "https://www.bilibili.com/audio/au777180")
    let video = try BilibiliLink("https://m.bilibili.com/video/BV1xx411c7mD?p=2")
    #expect(!video.isAudio && video.page == 2 && video.episodeID == "bilibili:BV1xx411c7mD:2")
    #expect(try BilibiliLink("https://www.bilibili.com/video/av170001").id == "av170001")
    #expect(try BilibiliLink("A video title https://b23.tv/AbC123").isShort)
    #expect(try BilibiliLink("Shared title https://www.bilibili.com/video/av170001").id == "av170001")
    for bad in ["http://www.bilibili.com/audio/au1", "https://bilibili.com.evil.test/audio/au1", "https://evil@www.bilibili.com/audio/au1", "https://www.bilibili.com/video/BVbad", "https://www.bilibili.com/video/av1?p=0", "https://www.bilibili.com/audio/au0", "https://www.bilibili.com/audio/au1?p=2", "https://www.bilibili.com/video/av1/extra"] {
        #expect(throws: ImportError.self) { try BilibiliLink(bad) }
    }
}

@Test func wbiMatchesDocumentedSignature() throws {
    let query = try WBI.query(["foo":"114", "bar":"514", "zab":"1919810"],
                              img: "7cd084941338484aae1ad9425b84077c", sub: "4932caff0ff746eab6f01bf08b70ac45", timestamp: 1702204169)
    #expect(query == "bar=514&foo=114&wts=1702204169&zab=1919810&w_rid=8f6f2b5b3d485fe1886cec6a0be8c5d4")
    #expect(throws: ImportError.self) { try WBI.query([:], img: "bad", sub: "bad", timestamp: 0) }
}

@MainActor @Test func maiTimestampsBecomeReaderSegmentsAndCannotOverwriteLearning() throws {
    let result = try JSONDecoder().decode(MAIResult.self, from: Data(maiJSON.utf8))
    let transcript = Transcript(title: "Test")
    try result.apply(to: transcript)
    #expect(transcript.duration == 3)
    #expect(transcript.orderedSegments.first?.start == 0.5)
    #expect(transcript.orderedSegments.first?.end == 2)
    #expect(transcript.orderedSegments.first?.speaker == "Speaker 1")
    #expect(transcript.sentences.first?.text == "Hello world.")
    #expect(throws: ImportError.self) { try result.apply(to: transcript) }
    for bad in [maiJSON.replacingOccurrences(of: ":500", with: ":-1"), maiJSON.replacingOccurrences(of: ":1500", with: ":9999"), maiJSON.replacingOccurrences(of: "Hello world.", with: " ")] {
        #expect(throws: ImportError.self) { try JSONDecoder().decode(MAIResult.self, from: Data(bad.utf8)).validate() }
    }
}

@Test func speechEndpointDoesNotSendKeysToArbitraryHosts() throws {
    let client = try MAITranscriber(endpoint: "https://study.cognitiveservices.azure.com", key: "test")
    #expect(client.endpoint.absoluteString == "https://study.cognitiveservices.azure.com/speechtotext/transcriptions:transcribe?api-version=2025-10-15")
    for bad in ["http://study.cognitiveservices.azure.com", "https://evil.test", "https://cognitiveservices.azure.com.evil.test", "https://study.cognitiveservices.azure.com/path", "https://study.cognitiveservices.azure.com?key=secret"] {
        #expect(throws: ImportError.self) { try MAITranscriber(endpoint: bad, key: "test") }
    }
    #expect(throws: ImportError.self) { try MAITranscriber(endpoint: "https://study.cognitiveservices.azure.com", key: "") }
    #expect(TransferRetryPolicy.retryAfter("12") == 12)
    #expect(TransferRetryPolicy.retryAfter("nonsense") == nil)
}

private final class TransferStub: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var mode = "success"
    static func reset(_ value: String) { lock.lock(); defer { lock.unlock() }; requests = []; mode = value }
    static func snapshot() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); let count = Self.requests.count; let mode = Self.mode; Self.lock.unlock()
        if mode == "routerFailSecond" && count >= 2 { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
        if (mode == "lostUpload" || mode == "exhaust") && (count == 1 || mode == "exhaust") {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return
        }
        var status = 200, json = maiJSON
        if mode == "unauthorized" { status = 401 }
        if mode == "throttled" && count == 1 { status = 429 }
        if mode == "lostResponse" && count == 1 {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"phrases":["#.utf8))
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return
        }
        if request.url!.path == "/api/v1/audio/transcriptions" {
            if mode == "routerNoTiming" { json = #"{"text":"Hello world."}"# }
            else { json = #"{"text":"Hello world.","duration":1,"segments":[{"text":"Hello world.","start":0,"end":0.8}],"words":[{"word":"Hello","start":0,"end":0.4},{"word":"world.","start":0.4,"end":0.8}]}"# }
        } else if request.url!.path.contains("song/info") { json = #"{"code":0,"data":{"title":"Study audio","author":"Teacher","uname":"Uploader","duration":3}}"# }
        else if request.url!.path.contains("web/url") {
            json = "{\"code\":0,\"data\":{\"type\":\(mode == "preview" ? -1 : 1),\"cdns\":[\"https://cdn.example.test/audio.m4a\",\"https://backup.example.test/audio.m4a\"]}}"
        } else if request.url!.path.hasSuffix("/view") {
            json = #"{"code":0,"data":{"bvid":"BV1xx411c7mD","title":"Study video","owner":{"name":"Teacher"},"pages":[{"cid":11,"page":1,"part":"First","duration":3},{"cid":22,"page":2,"part":"Second","duration":3}]}}"#
        } else if request.url!.path.hasSuffix("/nav") {
            json = #"{"code":-101,"data":{"wbi_img":{"img_url":"https://example.test/7cd084941338484aae1ad9425b84077c.png","sub_url":"https://example.test/4932caff0ff746eab6f01bf08b70ac45.png"}}}"#
        } else if request.url!.path.hasSuffix("/playurl") {
            json = #"{"code":0,"data":{"dash":{"audio":[{"baseUrl":"https://cdn.example.test/audio.m4a","mimeType":"audio/mp4","bandwidth":100}],"video":[{"base_url":"https://cdn.example.test/video.mp4","codecs":"avc1.64001E","bandwidth":500}]}}}"#
        }
        if request.url!.path.hasSuffix(".m4a") {
            if request.url!.host == "cdn.example.test" { status = 403 }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": mode == "html" ? "text/html" : "audio/mp4", "Content-Length":"65536"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(repeating: 42, count: 65536))
            client?.urlProtocolDidFinishLoading(self); return
        }
        let responseURL = request.url!.host == "b23.tv" ? URL(string: "https://www.bilibili.com/video/BV1xx411c7mD?p=2")! : request.url!
        let response = HTTPURLResponse(url: responseURL, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"application/json", "Retry-After":"0"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class UploadMonitor: EventMonitor, @unchecked Sendable {
    let queue = DispatchQueue(label: "PodcastLearning.UploadMonitor")
    private let lock = NSLock()
    private var bodies: [Data] = []
    func request(_ request: UploadRequest, didCreateUploadable uploadable: UploadRequest.Uploadable) {
        guard case .file(let url, _) = uploadable, let body = try? Data(contentsOf: url) else { return }
        lock.lock(); defer { lock.unlock() }; bodies.append(body)
    }
    func snapshot() -> [Data] { lock.lock(); defer { lock.unlock() }; return bodies }
}

@Suite(.serialized) struct TransferIntegrationTests {
    private func session(monitor: UploadMonitor = UploadMonitor()) -> Session {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TransferStub.self]
        return Session(configuration: config, interceptor: TransferRetryPolicy(retryLimit: 2, scale: 0), eventMonitors: [monitor])
    }
    @Test func bilibiliUsesAudioAPIAndSignedVideoParts() async throws {
        let session = session(), client = BilibiliClient(session: session)
        TransferStub.reset("success")
        let audio = try await client.resolve(BilibiliLink("https://www.bilibili.com/audio/au777180"))
        #expect(audio.title == "Study audio" && audio.audio.count == 2 && audio.video.isEmpty)
        #expect(TransferStub.snapshot().last?.url?.query?.contains("sid=777180") == true)
        #expect(TransferStub.snapshot().last?.value(forHTTPHeaderField: "Referer") == "https://www.bilibili.com/")
        TransferStub.reset("preview")
        await #expect(throws: ImportError.self) { try await client.resolve(BilibiliLink("https://www.bilibili.com/audio/au777180")) }
        TransferStub.reset("success")
        let video = try await client.resolve(BilibiliLink("https://www.bilibili.com/video/av170001?p=2"), includeVideo: true)
        #expect(video.link.page == 2 && video.video.count == 1 && video.audio.count == 1)
        #expect(TransferStub.snapshot().last?.url?.query?.contains("cid=22") == true)
        #expect(TransferStub.snapshot().last?.url?.query?.contains("w_rid=") == true)
        let expanded = try await client.expand(BilibiliLink("https://b23.tv/AbC123"))
        #expect(expanded.id == "BV1xx411c7mD" && expanded.page == 2)
        let audioOnly = try await client.resolve(BilibiliLink("https://www.bilibili.com/video/BV1xx411c7mD"))
        #expect(audioOnly.video.isEmpty)
    }
    @Test func downloadFallsBackWithoutReplacingGoodAudioWithErrors() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("audio.mp3"), session = session()
        let urls = [URL(string: "https://cdn.example.test/audio.m4a")!, URL(string: "https://backup.example.test/audio.m4a")!]
        TransferStub.reset("success")
        try await ReliableTransfer.download(urls, to: file, headers: BilibiliClient.headers, session: session)
        #expect(TransferStub.snapshot().count == 2)
        let good = try Data(contentsOf: file)
        #expect(good.count == 65536)
        TransferStub.reset("html")
        await #expect(throws: (any Error).self) { try await ReliableTransfer.download(urls, to: file, session: session) }
        #expect(try Data(contentsOf: file) == good)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["audio.mp3"])
    }
    @Test func openRouterChunksResumeWithoutReuploadingCompletedParts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wav = directory.appendingPathComponent("audio.wav")
        try silentWAV(wav, seconds: 301)
        let resultFile = directory.appendingPathComponent("result.json")
        let session = session()
        let client = try MAITranscriber(endpoint: "https://openrouter.ai/api/v1/", key: "test-key",
                                       model: "microsoft/mai-transcribe-2", session: session)
        #expect(client.isOpenRouter && client.endpoint.path == "/api/v1/audio/transcriptions")
        TransferStub.reset("routerFailSecond")
        await #expect(throws: (any Error).self) { try await client.transcribe(wav, resultFile: resultFile) }
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("result.part-0.json").path))
        #expect(!FileManager.default.fileExists(atPath: resultFile.path))
        TransferStub.reset("router")
        let result = try await client.transcribe(wav, resultFile: resultFile)
        #expect(TransferStub.snapshot().count == 1)
        #expect(result.durationMilliseconds == 301000 && result.phrases.count == 2)
        #expect(result.phrases[1].offsetMilliseconds == 300000)
        let request = try #require(TransferStub.snapshot().first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(request.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key") == nil)
        try FileManager.default.removeItem(at: wav)
        _ = try await client.transcribe(wav, resultFile: resultFile)
        #expect(TransferStub.snapshot().count == 1)
    }
    @Test func openRouterRequiresTimedResultsAndValidProviderURLs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wav = directory.appendingPathComponent("audio.wav"), result = directory.appendingPathComponent("result.json")
        try silentWAV(wav, seconds: 2)
        let session = session(), monitor = UploadMonitor()
        let monitored = self.session(monitor: monitor)
        let client = try MAITranscriber(endpoint: "https://openrouter.ai/api/v1", key: "test-key", session: monitored)
        TransferStub.reset("routerNoTiming")
        await #expect(throws: ImportError.self) { try await client.transcribe(wav, resultFile: result) }
        #expect(!FileManager.default.fileExists(atPath: result.path))
        let bodies = monitor.snapshot().map { String(decoding: $0, as: UTF8.self) }
        #expect(bodies.contains { $0.contains("microsoft/mai-transcribe-2") && $0.contains("verbose_json") && $0.contains("timestamp_granularities[]") && $0.contains(#"name="file""#) })
        for url in ["https://openrouter.ai", "https://openrouter.ai/api/v1/audio/transcriptions", "https://openrouter.ai.evil.test/api/v1"] {
            #expect(throws: ImportError.self) { try MAITranscriber(endpoint: url, key: "test-key", session: session) }
        }
    }
    @Test func uploadAndResponseLossRetryAndCacheSurvivesRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("audio.wav")
        try Data(repeating: 0, count: 32044).write(to: audio)
        let monitor = UploadMonitor()
        let session = session(monitor: monitor)
        let client = try MAITranscriber(endpoint: "https://study.cognitiveservices.azure.com", key: "test-key", session: session)
        for mode in ["lostUpload", "lostResponse", "throttled"] {
            TransferStub.reset(mode)
            let resultFile = directory.appendingPathComponent(mode + ".json")
            let result = try await client.transcribe(audio, resultFile: resultFile)
            #expect(result.phrases.first?.text == "Hello world.")
            let requests = TransferStub.snapshot()
            #expect(requests.count == 2)
            #expect(requests.allSatisfy { $0.httpMethod == "POST" && $0.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key") == "test-key" && $0.value(forHTTPHeaderField: "Content-Type")?.contains("multipart/form-data") == true })
            let relaunched = try MAITranscriber(endpoint: "https://study.cognitiveservices.azure.com", key: "test-key", session: session)
            _ = try await relaunched.transcribe(audio, resultFile: resultFile)
            #expect(TransferStub.snapshot().count == 2)
        }
        let bodies = monitor.snapshot()
        #expect(!bodies.isEmpty)
        #expect(bodies.allSatisfy {
            let text = String(decoding: $0, as: UTF8.self)
            return text.contains("name=\"audio\"") && text.contains("audio.wav") && text.contains("name=\"definition\"") &&
                text.contains("MAI-Transcribe-2") && text.contains("\"timestamps\":\"word\"")
        })
        for (mode, count) in [("unauthorized", 1), ("exhaust", 3)] {
            TransferStub.reset(mode)
            let resultFile = directory.appendingPathComponent(mode + ".json")
            await #expect(throws: (any Error).self) { try await client.transcribe(audio, resultFile: resultFile) }
            #expect(TransferStub.snapshot().count == count)
            #expect(!FileManager.default.fileExists(atPath: resultFile.path))
            #expect(FileManager.default.fileExists(atPath: audio.path))
        }
    }
}

@Test func audioPreparationWritesMono16kWAVAndReusesCompletedFile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.caf"), destination = directory.appendingPathComponent("audio.wav")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
    do {
        let file = try AVAudioFile(forWriting: source, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
        buffer.frameLength = 48000
        for channel in 0..<2 { for index in 0..<48000 { buffer.floatChannelData![channel][index] = Float(sin(Double(index) * 0.02)) * 0.1 } }
        try file.write(from: buffer)
    }
    try AudioPreparation.wav(from: source, to: destination)
    let prepared = try AVAudioFile(forReading: destination)
    #expect(prepared.processingFormat.sampleRate == 16000 && prepared.processingFormat.channelCount == 1)
    #expect(abs(prepared.length - 16000) < 100)
    try FileManager.default.removeItem(at: source)
    try AudioPreparation.wav(from: source, to: destination)
    #expect(try destination.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
}

@Test func retainedVideoMuxesTheAudioAndVideoTracks() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let audio = directory.appendingPathComponent("audio.m4a"), video = directory.appendingPathComponent("video.mp4")
    let output = directory.appendingPathComponent("retained.mp4")
    try fixture("bilibili-audio.m4a").write(to: audio)
    try fixture("bilibili-video.mp4").write(to: video)
    try await AudioPreparation.video(audio: audio, track: video, to: output)
    let asset = AVURLAsset(url: output)
    #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
    #expect(try await asset.load(.duration).seconds > 0.9)
    #expect(try output.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    let id = UUID(); defer { try? AudioStore.delete(id) }
    let cached = try AudioStore.bilibiliFile(id), wav = directory.appendingPathComponent("prepared.wav")
    try fixture("bilibili-audio.m4a").write(to: cached)
    #expect(AudioStore.localURL(id) == cached)
    try AudioPreparation.wav(from: cached, to: wav)
    #expect(try AVAudioFile(forReading: wav).length > 15000)
}

@MainActor @Test func maiWordTimingSplitsLongPhrasesIntoPracticeClips() throws {
    let json = #"{"durationMilliseconds":40000,"phrases":[{"text":"Hello world. Keep listening","offsetMilliseconds":0,"durationMilliseconds":40000,"words":[{"text":"Hello","offsetMilliseconds":500,"durationMilliseconds":500},{"text":"world.","offsetMilliseconds":1000,"durationMilliseconds":500},{"text":"Keep","offsetMilliseconds":2000,"durationMilliseconds":500},{"text":"listening","offsetMilliseconds":33000,"durationMilliseconds":500}]}]}"#
    let result = try JSONDecoder().decode(MAIResult.self, from: Data(json.utf8)), transcript = Transcript(title: "Practice")
    try result.apply(to: transcript)
    #expect(transcript.orderedSegments.map(\.text) == ["Hello world.", "Keep listening"])
    #expect(transcript.orderedSegments.map(\.start) == [0.5, 2])
    #expect(transcript.orderedSegments.map(\.end) == [1.5, 33.5])
    let invalid = json.replacingOccurrences(of: "\"offsetMilliseconds\":33000", with: "\"offsetMilliseconds\":-1")
    #expect(throws: ImportError.self) { try JSONDecoder().decode(MAIResult.self, from: Data(invalid.utf8)).validate() }
}

private func silentWAV(_ file: URL, seconds: Int) throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
    let output = try AVAudioFile(forWriting: file, settings: format.settings)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
    buffer.frameLength = 16000
    buffer.floatChannelData![0].initialize(repeating: 0, count: 16000)
    for _ in 0..<seconds { try output.write(from: buffer) }
}
