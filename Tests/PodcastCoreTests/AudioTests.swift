import Foundation
import Testing
@testable import PodcastCore

private final class AudioProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        if path == "/offline" { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        var headers = ["Content-Type": path == "/html" ? "text/html" : "audio/mpeg"]
        if path != "/unknown" { headers["Content-Length"] = "65536" }
        let response = HTTPURLResponse(url: request.url!, statusCode: path == "/fail" ? 503 : 200, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 42, count: 65536))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func audioDownloadCanRetryWithoutReplacingGoodAudioWithAnError() async throws {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AudioProtocol.self]
    let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
    let id = UUID(); defer { try? AudioStore.delete(id) }
    for path in ["fail", "html", "offline"] {
        do {
            try await AudioStore.download(URL(string: "https://example.com/\(path)")!, id: id, session: session)
            Issue.record("Invalid audio download was accepted")
        } catch {
            if path == "fail" { #expect(error.localizedDescription.contains("Episode audio download failed (HTTP 503)")) }
            if path == "html" { #expect(error.localizedDescription.contains("text/JSON instead of audio (HTTP 200)")) }
        }
        #expect(AudioStore.localURL(id) == nil)
    }
    let progress = ProgressValues()
    try await AudioStore.download(URL(string: "https://example.com/audio")!, id: id, session: session) { progress.append($0) }
    #expect(progress.snapshot().contains(1))
    #expect(AudioStore.size(id) == 65536)
    #expect(try AudioStore.localURL(id)?.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    await #expect(throws: ImportError.self) { try await AudioStore.download(URL(string: "https://example.com/fail")!, id: id, session: session) }
    #expect(AudioStore.size(id) == 65536)
    try await AudioStore.download(URL(string: "https://example.com/audio")!, id: id, session: session)
    #expect(AudioStore.size(id) == 65536)
    await #expect(throws: ImportError.self) { try await AudioStore.download(URL(string: "file:///tmp/audio.mp3")!, id: id, session: session) }
}

private final class ProgressValues: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double?] = []
    func append(_ value: Double?) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func snapshot() -> [Double?] { lock.lock(); defer { lock.unlock() }; return values }
}

@Test func downloadProgressHandlesUnknownLength() async throws {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AudioProtocol.self]
    let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
    let id = UUID(); defer { try? AudioStore.delete(id) }
    let values = ProgressValues()
    try await AudioStore.download(URL(string: "https://example.com/unknown")!, id: id, session: session) { values.append($0) }
    #expect(!values.snapshot().isEmpty)
    #expect(values.snapshot().allSatisfy { $0 == nil })
    #expect(AudioStore.size(id) == 65536)
}


@Test func paragraphSeekIsClampedToItsOwnAudioRange() throws {
    let range = try #require(PlaybackRange(start: 59, end: 80))
    #expect(range.time(at: 0) == 59)
    #expect(range.time(at: 0.5) == 69.5)
    #expect(range.time(at: 1) == 80)
    #expect(range.time(at: -0.5) == 59)
    #expect(range.time(at: 1.5) == 80)
    #expect(range.time(at: .nan) == 59)
    #expect(range.time(at: .infinity) == 59)
    for fraction in stride(from: 0.0, through: 1, by: 0.01) {
        #expect(abs(range.fraction(at: range.time(at: fraction)) - fraction) < 0.000001)
    }
}

@Test func playbackRangeRejectsInvalidTimingAndClampsProgress() throws {
    #expect(PlaybackRange(start: -1, end: 80) == nil)
    #expect(PlaybackRange(start: 80, end: 59) == nil)
    #expect(PlaybackRange(start: 59, end: 59) == nil)
    #expect(PlaybackRange(start: .nan, end: 80) == nil)
    #expect(PlaybackRange(start: 59, end: .infinity) == nil)
    let range = try #require(PlaybackRange(start: 59, end: 80))
    #expect(range.fraction(at: 20) == 0)
    #expect(range.fraction(at: 100) == 1)
    #expect(range.fraction(at: .nan) == 0)
}

@Test func libraryMediaRemovalDeletesOnlyThatTranscriptsFilesAndCheckpoints() throws {
    let id = UUID(), keptID = UUID()
    defer { try? AudioStore.delete(id); try? AudioStore.delete(keptID) }
    let files = try [AudioStore.file(id), AudioStore.bilibiliFile(id), AudioStore.videoFile(id),
                     AudioStore.workDirectory(id).appendingPathComponent("result.json")]
    let kept = try AudioStore.file(keptID)
    for file in files + [kept] { try Data("saved".utf8).write(to: file) }

    try AudioStore.delete(id)

    #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    #expect(!FileManager.default.fileExists(atPath: try AudioStore.directory().appendingPathComponent(id.uuidString).path))
    #expect(try Data(contentsOf: kept) == Data("saved".utf8))
    try AudioStore.delete(id)
}
