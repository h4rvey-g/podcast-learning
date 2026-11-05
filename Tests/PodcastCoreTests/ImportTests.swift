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

@Test func sharedImportAppGroupSupportsSideStoreResigning() {
    let configured = "group.com.example.PodcastLearning"
    #expect(PendingImport.appGroupIdentifier(in: ["AppGroupIdentifier": configured]) == configured)
    #expect(PendingImport.appGroupIdentifier(in: [
        "AppGroupIdentifier": configured,
        "ALTAppGroups": ["group.unrelated.TEAM123", configured + ".TEAM123"]
    ]) == configured + ".TEAM123")
    #expect(PendingImport.appGroupIdentifier(in: [
        "AppGroupIdentifier": configured, "ALTAppGroups": ["group.unrelated.TEAM123"]
    ]) == configured)
    #expect(PendingImport.appGroupIdentifier(in: [:]) == nil)
    #expect(PendingImport.appGroupIdentifier(in: ["AppGroupIdentifier": ""]) == nil)
}

@Test func sharedImportUsesProvisionedGroupWithoutInstallerMetadata() throws {
    let configured = "group.com.howieguo8.PodcastLearning"
    let signedGroup = configured + ".Y77KRPY77N"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let profile = try PropertyListSerialization.data(fromPropertyList: [
        "Entitlements": ["com.apple.security.application-groups": [signedGroup]]
    ], format: .xml, options: 0)
    for (name, identifier) in [
        ("App", "com.howieguo8.PodcastLearning.Y77KRPY77N"),
        ("Extension", "com.howieguo8.PodcastLearning.Y77KRPY77N.Share")
    ] {
        let url = directory.appendingPathComponent(name + ".bundle")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "AppGroupIdentifier": configured]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Info.plist"))
        try (Data([0x30, 0x82, 0xff, 0x00]) + profile + Data([0x00, 0xff]))
            .write(to: url.appendingPathComponent("embedded.mobileprovision"))
        let bundle = try #require(Bundle(url: url))
        #expect(PendingImport.appGroupIdentifier(in: bundle) == signedGroup, "\(name) must use the provisioned group")
    }
    let staleInstallerInfo: [String: Any] = ["AppGroupIdentifier": configured, "ALTAppGroups": [configured + ".OLDTEAM"]]
    #expect(PendingImport.appGroupIdentifier(in: staleInstallerInfo, provisioningProfile: profile) == signedGroup)
    #expect(PendingImport.appGroupIdentifier(in: staleInstallerInfo, provisioningProfile: Data([0x00, 0xff])) == configured + ".OLDTEAM")
    let unrelated = try PropertyListSerialization.data(fromPropertyList: [
        "Entitlements": ["com.apple.security.application-groups": [configured + "Other.Y77KRPY77N"]]
    ], format: .xml, options: 0)
    #expect(PendingImport.appGroupIdentifier(in: ["AppGroupIdentifier": configured], provisioningProfile: unrelated) == configured)
}

@Test func sharedImportDiagnosticsReportOnlySigningIdentifiers() throws {
    let configured = "group.com.example.PodcastLearning"
    let signedGroup = configured + ".TEAM123"
    let plist = try PropertyListSerialization.data(fromPropertyList: [
        "Name": "PRIVATE_PROFILE_NAME", "ProvisionedDevices": ["PRIVATE_DEVICE_ID"],
        "Entitlements": ["com.apple.security.application-groups": [signedGroup]]
    ], format: .xml, options: 0)
    let profile = Data([0x30, 0x82, 0xff, 0x00]) + plist + Data([0x00, 0xff])
    let info: [String: Any] = ["AppGroupIdentifier": configured, "CFBundleIdentifier": "com.example.PodcastLearning.Share"]
    let report = PendingImport.appGroupDiagnostics(in: info, provisioningProfile: profile)
    #expect(report.contains("Share signing diagnostics 3"))
    #expect(report.components(separatedBy: "\n").contains("Selected: " + signedGroup))
    #expect(report.contains("Installer groups: none"))
    #expect(report.contains("Profile groups: " + signedGroup))
    #expect(!report.contains("PRIVATE_PROFILE_NAME") && !report.contains("PRIVATE_DEVICE_ID"))
    #expect(PendingImport.appGroupDiagnostics(in: info, provisioningProfile: nil).contains("Profile groups: profile unavailable"))
    #expect(PendingImport.appGroupDiagnostics(in: info, provisioningProfile: Data([0x00, 0xff])).contains("Profile groups: profile unreadable"))
    let noGroups = try PropertyListSerialization.data(fromPropertyList: ["Entitlements": [String: String]()], format: .xml, options: 0)
    #expect(PendingImport.appGroupDiagnostics(in: info, provisioningProfile: noGroups).contains("Profile groups: none"))
    let installerInfo = info.merging(["ALTAppGroups": [signedGroup]]) { _, new in new }
    #expect(PendingImport.appGroupDiagnostics(in: installerInfo, provisioningProfile: profile).contains("Installer groups: " + signedGroup))
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let path = request.url!.path
            let data: Data
            var status = path == "/fail" ? 503 : 200
            if path == "/api/transcript" {
                guard request.httpMethod == "POST", request.value(forHTTPHeaderField: "Content-Type") == "application/json" else { throw ImportError.invalidResponse }
                switch request.value(forHTTPHeaderField: "Test-Scenario") {
                case "expired-502", "expired-200":
                    status = request.value(forHTTPHeaderField: "Test-Scenario") == "expired-502" ? 502 : 200
                    data = Data(#"{"success":false,"code":"","error":"Apple Media Token has expired. Please update bearer token."}"#.utf8)
                case "missing":
                    status = 404
                    data = Data(#"{"success":false,"code":"no_transcript","error":"No transcript for this episode."}"#.utf8)
                case "blocked":
                    status = 403; data = Data("<html>Private gateway details</html>".utf8)
                case "empty-error":
                    status = 503; data = Data(#"{"success":false,"error":"  "}"#.utf8)
                case "success-on-error":
                    status = 502; data = try fixture("podtext.json")
                default: data = try fixture("podtext.json")
                }
            } else if path == "/lookup" {
                if request.url?.query?.contains("id=42&") == true {
                    data = Data(#"{"results":[{"trackId":42,"feedUrl":"https://example.com/feed.xml"}]}"#.utf8)
                } else { data = try fixture("itunes.json") }
            }
            else if path == "/feed.xml" { data = try fixture("feed.xml") }
            else { data = Data() }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor @Test(arguments: ["expired-502", "expired-200", "missing", "blocked", "empty-error", "success-on-error"])
func podTextFailuresExplainUpstreamCause(scenario: String) async throws {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
    config.httpAdditionalHeaders = ["Test-Scenario": scenario]
    let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
    let link = try EpisodeLink("https://podcasts.apple.com/us/podcast/a-show/id1200361736?i=1000799212333")
    do {
        let response = try await PodTextClient().fetch(link, uid: "test-uid", session: session)
        _ = try response.transcript()
        Issue.record("A failed PodText response must not produce an imported transcript")
    } catch let error as ImportError {
        let message = error.localizedDescription
        #expect(message.contains("PodText"))
        if scenario.hasPrefix("expired-") {
            #expect(message.contains("PodText needs to restore"))
            #expect(!message.contains("update bearer token"))
        } else if scenario == "missing" {
            #expect(message.contains("HTTP 404") && message.contains("No transcript for this episode."))
        } else {
            let status = scenario == "blocked" ? 403 : scenario == "empty-error" ? 503 : 502
            #expect(message.contains("HTTP \(status)"))
            #expect(message.contains("import a transcript file"))
            #expect(!message.contains("Private gateway details"))
        }
    }
}

@Test func clientsUseExpectedEndpointsAndRejectHTTPFailures() async throws {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
    let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
    let link = try EpisodeLink("https://podcasts.apple.com/us/podcast/a-show/id1200361736?i=1000799212333")
    let response = try await PodTextClient().fetch(link, uid: "test-uid", session: session)
    #expect(response.success)
    let audio = try #require(await AudioResolver.resolve(link, title: "anything", session: session))
    #expect(audio.url.absoluteString == "https://example.com/two.mp3")
    #expect(audio.duration == 2172)
    let thinned = try EpisodeLink("https://podcasts.apple.com/us/podcast/a-show/id42?i=99")
    #expect(try await AudioResolver.resolve(thinned, title: "Want to Enjoy Music More? Go for a Run", session: session)?.url.absoluteString == "https://example.com/two.mp3")
    await #expect(throws: ImportError.self) { try await HTTP.data(for: URLRequest(url: URL(string: "https://example.com/fail")!), session: session) }
}
