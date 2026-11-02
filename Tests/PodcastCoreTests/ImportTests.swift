import Foundation
import Testing
@testable import PodcastCore

@Test func episodeLinkValidation() throws {
    let link = try EpisodeLink("https://podcasts.apple.com/us/podcast/a-show/id1200361736?i=1000799212333")
    #expect(link.showID == "1200361736" && link.episodeID == "1000799212333")
    for bad in ["https://example.com/id1?i=2", "https://podcasts.apple.com.evil.com/id1?i=2", "http://podcasts.apple.com/id1?i=2", "https://podcasts.apple.com/id1", "https://podcasts.apple.com/id1?i=abc"] {
        #expect(throws: ImportError.self) { try EpisodeLink(bad) }
    }
}

@MainActor @Test func podTextDecoding() throws {
    let response = try JSONDecoder().decode(PodTextResponse.self, from: fixture("podtext.json"))
    let transcript = try response.transcript()
    #expect(transcript.title == "Want to Enjoy Music More? Go for a Run")
    #expect(transcript.orderedSegments.count == 2)
    #expect(transcript.orderedSegments[0].start == 72.9)
    #expect(transcript.sentences.count == 3)
    let failure = try JSONDecoder().decode(PodTextResponse.self, from: Data(#"{"success":false,"error":"No transcript","code":"no_transcript"}"#.utf8))
    #expect(throws: ImportError.self) { try failure.transcript() }
}

@Test func rssAndITunesDecoding() throws {
    let items = try RSSParser.parse(fixture("feed.xml"))
    #expect(items.count == 2)
    #expect(AudioResolver.match(items, guid: "episode-guid", title: "unknown")?.absoluteString == "https://example.com/two.mp3")
    #expect(AudioResolver.match(items, guid: nil, title: "WANT TO ENJOY MUSIC MORE — GO FOR A RUN")?.absoluteString == "https://example.com/two.mp3")
    #expect(AudioResolver.match(items, guid: nil, title: "missing") == nil)
    let lookup = try JSONDecoder().decode(ITunesResponse.self, from: fixture("itunes.json"))
    #expect(lookup.results[1].trackId == 1000799212333)
    #expect(throws: ImportError.self) { try RSSParser.parse(Data("<broken".utf8)) }
}

@Test func pendingImportRoundTrip() throws {
    let pending = PendingImport(text: "Hello world.", fileExtension: "srt", title: "Test")
    let decoded = try JSONDecoder().decode(PendingImport.self, from: JSONEncoder().encode(pending))
    #expect(decoded.text == pending.text && decoded.fileExtension == "srt" && decoded.title == "Test")
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let path = request.url!.path
            let data: Data
            if path == "/api/transcript" {
                guard request.httpMethod == "POST", request.value(forHTTPHeaderField: "Content-Type") == "application/json" else { throw ImportError.invalidResponse }
                data = try fixture("podtext.json")
            } else if path == "/lookup" {
                if request.url?.query?.contains("id=42&") == true {
                    data = Data(#"{"results":[{"trackId":42,"feedUrl":"https://example.com/feed.xml"}]}"#.utf8)
                } else { data = try fixture("itunes.json") }
            }
            else if path == "/feed.xml" { data = try fixture("feed.xml") }
            else { data = Data() }
            let response = HTTPURLResponse(url: request.url!, statusCode: path == "/fail" ? 503 : 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@Test func clientsUseExpectedEndpointsAndRejectHTTPFailures() async throws {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
    let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
    let link = try EpisodeLink("https://podcasts.apple.com/us/podcast/a-show/id1200361736?i=1000799212333")
    let response = try await PodTextClient().fetch(link, uid: "test-uid", session: session)
    #expect(response.success)
    #expect(try await AudioResolver.resolve(link, title: "anything", session: session)?.absoluteString == "https://example.com/two.mp3")
    let thinned = try EpisodeLink("https://podcasts.apple.com/us/podcast/a-show/id42?i=99")
    #expect(try await AudioResolver.resolve(thinned, title: "Want to Enjoy Music More? Go for a Run", session: session)?.absoluteString == "https://example.com/two.mp3")
    await #expect(throws: ImportError.self) { try await HTTP.data(for: URLRequest(url: URL(string: "https://example.com/fail")!), session: session) }
}
