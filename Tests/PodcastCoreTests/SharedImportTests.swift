import Foundation
import Testing
import UniformTypeIdentifiers
@testable import PodcastCore

@MainActor @Test func sharedImportPrefersLinkToEarlierTitle() async throws {
    let title = "【每日英语新闻】摄入过多超加工食品易致大脑损伤！"
    let link = URL(string: "https://b23.tv/abc123")!
    let pending = try await loadProviders([textProvider(title), urlProvider(link)])
    #expect(pending.text == link.absoluteString)
}

@MainActor @Test func sharedImportPrefersLinkInLaterTextAttachment() async throws {
    let pending = try await loadProviders([textProvider("A video title"), textProvider("Watch this https://b23.tv/abc123")])
    #expect(pending.text == "https://b23.tv/abc123")
}

@MainActor @Test func sharedImportAcceptsPodcastAndPlainText() async throws {
    let link = "https://podcasts.apple.com/us/podcast/a-show/id1200361736?i=1000799212333"
    let podcast = try await loadProviders([urlProvider(URL(string: link)!)])
    #expect(podcast.text == link)
    let text = try await loadProviders([textProvider("An English transcript.")])
    #expect(text.text == "An English transcript.")
}

@MainActor @Test func sharedImportReadsFilesAndRejectsOversizedContent() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("srt")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("1\n00:00:00,000 --> 00:00:01,000\nHello world.\n".utf8).write(to: url)
    let pending = try await loadProviders([urlProvider(url)])
    #expect(pending.fileExtension == "srt" && pending.text.contains("Hello world."))
    try Data(repeating: 65, count: 5_000_001).write(to: url)
    await #expect(throws: ImportError.self) { try await loadProviders([urlProvider(url)]) }
    await #expect(throws: ImportError.self) { try await loadProviders([textProvider(String(repeating: "a", count: 5_000_001))]) }
}

@MainActor @Test func sharedImportReadsItemBodyAndDataRepresentations() async throws {
    let title = NSExtensionItem()
    title.attachments = [textProvider("A podcast title")]
    let body = NSExtensionItem()
    let link = "https://podcasts.apple.com/us/podcast/a-show/id1200361736?i=1000799212333"
    body.attributedContentText = NSAttributedString(string: "Listen: " + link)
    let pending = try await PendingImport.load(from: [title, body])
    #expect(pending.text == link)

    let provider = NSItemProvider()
    provider.registerDataRepresentation(forTypeIdentifier: UTType.url.identifier, visibility: .all) { completion in
        DispatchQueue.global().async { completion(Data("https://b23.tv/abc123".utf8), nil) }
        return nil
    }
    let url = try await loadProviders([textProvider("A video title"), provider])
    #expect(url.text == "https://b23.tv/abc123")
}

@MainActor @Test func sharedImportContinuesAfterBrokenRepresentation() async throws {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(forTypeIdentifier: UTType.url.identifier, visibility: .all) { completion in
        completion(nil, NSError(domain: "SharedImportTests", code: 1))
        return nil
    }
    let pending = try await loadProviders([provider, textProvider("Watch https://b23.tv/abc123")])
    #expect(pending.text == "https://b23.tv/abc123")
    await #expect(throws: (any Error).self) { try await loadProviders([provider, textProvider("A title without a link")]) }
    await #expect(throws: ImportError.self) { try await loadProviders([]) }
    let wrong = urlProvider(URL(string: "https://bilibili.com.evil.example/video/BV1iu4y1K7UE")!)
    let link = try await loadProviders([wrong, urlProvider(URL(string: "https://b23.tv/abc123")!)])
    #expect(link.text == "https://b23.tv/abc123")
}

@MainActor @Test func sharedImportRejectsUnsupportedOrInvalidFiles() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try Data([0xff, 0xfe, 0x00]).write(to: url)
    await #expect(throws: ImportError.self) { try await loadProviders([urlProvider(url)]) }
    let txt = url.appendingPathExtension("txt")
    defer { try? FileManager.default.removeItem(at: txt) }
    try Data([0xff, 0xfe, 0x00]).write(to: txt)
    await #expect(throws: ImportError.self) { try await loadProviders([urlProvider(txt)]) }
}

@MainActor @Test func sharedImportLoadsArchivedURLThroughNativeURLAPI() async throws {
    let provider = ArchivedURLProvider(item: NSURL(string: "https://b23.tv/abc123")!, typeIdentifier: UTType.url.identifier)
    let pending = try await loadProviders([textProvider("A video title"), provider])
    #expect(pending.text == "https://b23.tv/abc123")
}

private final class ArchivedURLProvider: NSItemProvider, @unchecked Sendable {
    override func loadDataRepresentation(forTypeIdentifier typeIdentifier: String, completionHandler: @escaping @Sendable (Data?, (any Error)?) -> Void) -> Progress {
        // On-device tracing shows iOS supplies an NSURL archive here, not UTF-8 URL bytes.
        do { completionHandler(try NSKeyedArchiver.archivedData(withRootObject: NSURL(string: "https://b23.tv/abc123")!, requiringSecureCoding: true), nil) }
        catch { completionHandler(nil, error) }
        return Progress(totalUnitCount: 1)
    }
    override func loadObject(ofClass aClass: any NSItemProviderReading.Type, completionHandler: @escaping @Sendable ((any NSItemProviderReading)?, (any Error)?) -> Void) -> Progress {
        completionHandler(NSURL(string: "https://b23.tv/abc123")!, nil)
        return Progress(totalUnitCount: 1)
    }
}

private func textProvider(_ text: String) -> NSItemProvider {
    NSItemProvider(item: text as NSString, typeIdentifier: UTType.plainText.identifier)
}

private func urlProvider(_ url: URL) -> NSItemProvider {
    NSItemProvider(item: url as NSURL, typeIdentifier: url.isFileURL ? UTType.fileURL.identifier : UTType.url.identifier)
}

@MainActor private func loadProviders(_ providers: [NSItemProvider]) async throws -> PendingImport {
    let item = NSExtensionItem()
    item.attachments = providers
    return try await PendingImport.load(from: [item])
}
