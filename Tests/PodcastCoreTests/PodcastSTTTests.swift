import Foundation
import Testing
@testable import PodcastCore

private final class PodcastPageProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            #expect(request.url?.host == "podcasts.apple.com", "STT preview must not depend on PodText or the thinned iTunes index")
            var html = String(decoding: try fixture("apple-episode.html"), as: UTF8.self)
            switch request.value(forHTTPHeaderField: "Test-Scenario") {
            case "wrong-episode": html = html.replacingOccurrences(of: "1000799212333", with: "999")
            case "wrong-show": html = html.replacingOccurrences(of: "1200361736", with: "999")
            case "subscription": html = html.replacingOccurrences(of: "STDQ", with: "subscription")
            case "invalid-url": html = html.replacingOccurrences(of: "https://example.com/two.mp3", with: "file:///private/audio.mp3")
            case "missing-script": html = "<html>Service unavailable</html>"
            case "invalid-json": html = html.replacingOccurrences(of: "{\"data\":", with: "{broken:")
            default: break
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(html.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor @Test func podcastSTTPreviewFindsExactEpisodeWithoutPodText() async throws {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PodcastPageProtocol.self]
    let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
    let link = try EpisodeLink("https://podcasts.apple.com/us/podcast/a-show/id1200361736?i=1000799212333")
    let preview = try await AudioResolver.preview(link, session: session)
    #expect(preview.episodeID == link.episodeID && preview.sourceURL == link.url.absoluteString)
    #expect(preview.title == "Want to Enjoy Music More? Go for a Run" && preview.author == "The Daily")
    #expect(preview.remoteAudioURL == "https://example.com/two.mp3")
    #expect(preview.audioDuration == 2172 && preview.coverURL == "https://example.com/cover/600x600bb.jpg")
    #expect(preview.orderedSegments.isEmpty, "STT text is generated after the session is saved")
}

@MainActor @Test(arguments: ["wrong-episode", "wrong-show", "subscription", "invalid-url", "missing-script", "invalid-json"])
func podcastSTTPreviewRejectsUnavailableOrInvalidAudio(scenario: String) async throws {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PodcastPageProtocol.self]
    config.httpAdditionalHeaders = ["Test-Scenario": scenario]
    let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
    let link = try EpisodeLink("https://podcasts.apple.com/us/podcast/a-show/id1200361736?i=1000799212333")
    await #expect(throws: (any Error).self) { try await AudioResolver.preview(link, session: session) }
}
