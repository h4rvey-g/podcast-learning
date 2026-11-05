import Foundation
import Testing
@testable import PodcastCore

private final class CatalogProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let scenario = request.value(forHTTPHeaderField: "Test-Scenario") ?? "success"
        let models = request.url?.path.hasSuffix("models") == true
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == nil)
        #expect(request.timeoutInterval == 15)
        if models { #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "speech") }
        let body: String
        if scenario == "malformed" { body = "{}" }
        else if models {
            body = """
            {"data":[
                {"id":"elevenlabs/old","name":"Old","created":1,"endpoints":["/api/v1/audio/speech"],"supported_voices":["george","sarah"]},
                {"id":"elevenlabs/scribe","name":"Transcription","created":3,"endpoints":["/api/v1/audio/transcriptions"],"supported_voices":null},
                {"id":"other/tts","name":"Other","created":4,"endpoints":["/api/v1/audio/speech"],"supported_voices":["george"]},
                {"id":"elevenlabs/new","name":"New","created":2,"endpoints":["/api/v1/audio/speech"],"supported_voices":["sarah"]},
                {"id":"elevenlabs/new","name":"Duplicate","created":2,"endpoints":["/api/v1/audio/speech"],"supported_voices":["sarah"]}
            ]}
            """
        } else {
            body = """
            {"voices":[
                {"voice_id":"voice-george","name":"George - Warm, Captivating Storyteller","preview_url":"https://storage.googleapis.com/example.mp3"},
                {"voice_id":"voice-sarah","name":"Sarah - Confident","preview_url":null},
                {"voice_id":"unsafe","name":"Unsafe","preview_url":"http://example.com/sample.mp3"},
                {"voice_id":"credentials","name":"Credentials","preview_url":"https://secret@example.com/sample.mp3"}
            ]}
            """
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: scenario == "failure" ? 503 : 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct SpeechCatalogTests {
    private func session(_ scenario: String = "success") -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogProtocol.self]
        configuration.httpAdditionalHeaders = ["Test-Scenario": scenario]
        return URLSession(configuration: configuration)
    }
    @Test func discoversLatestElevenLabsSpeechModelsAndPerModelVoices() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let models = try await SpeechCatalog.models(session: session)
        #expect(models.map(\.id) == ["elevenlabs/new", "elevenlabs/old"])
        #expect(models[0].supportedVoices == ["sarah"])
        #expect(models[1].supportedVoices == ["george", "sarah"])
    }
    @Test func matchesSupportedVoiceAliasesAndIDsToPublicSamples() async throws {
        let session = session(); defer { session.invalidateAndCancel() }
        let voices = try await SpeechCatalog.voices(session: session)
        let george = try #require(voices.first)
        #expect(george.matches("george"))
        #expect(george.matches("GEORGE"))
        #expect(george.matches("voice-george"))
        #expect(!george.matches("sarah"))
        #expect(george.sampleURL?.scheme == "https")
        #expect(voices.dropFirst().allSatisfy { $0.sampleURL == nil })
    }
    @Test(arguments: ["failure", "malformed"]) func rejectsFailedAndMalformedCatalogs(_ scenario: String) async {
        let session = session(scenario); defer { session.invalidateAndCancel() }
        await #expect(throws: (any Error).self) { try await SpeechCatalog.models(session: session) }
        await #expect(throws: (any Error).self) { try await SpeechCatalog.voices(session: session) }
    }
}
