import Foundation
import UniformTypeIdentifiers

extension PendingImport {
    @MainActor public static func load(from items: [NSExtensionItem]) async throws -> PendingImport {
        let providers = items.flatMap { $0.attachments ?? [] }
        var fallback: PendingImport?
        var loadingError: Error?
        // Titles and links can be separate attachments; inspect URL representations before accepting text.
        for type in [UTType.fileURL.identifier, UTType.url.identifier, UTType.plainText.identifier] {
            for provider in providers where provider.hasItemConformingToTypeIdentifier(type) {
                do {
                    try Task.checkCancellation()
                    if type == UTType.fileURL.identifier {
                        // Preserve security-scoped file URL objects supplied by Files providers.
                        let value = try await provider.loadItem(forTypeIdentifier: type)
                        if let url = value as? URL, url.isFileURL { return try transcriptFile(url) }
                    }
                    if type == UTType.url.identifier, let url = try? await sharedURL(from: provider) {
                        try Task.checkCancellation()
                        return try importSharedURL(url)
                    }
                    let data = try await sharedData(from: provider, type: type)
                    try Task.checkCancellation()
                    guard data.count <= 5_000_000 else { throw ImportError.tooLarge }
                    // Legacy providers can return a securely archived NSString instead of UTF-8 bytes.
                    let decoded = String(data: data, encoding: .utf8)
                        ?? (try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSString.self, from: data)).map { $0 as String }
                    guard let text = decoded else {
                        throw ImportError.service("Couldn't read the shared item (\(type), \(data.count) bytes). Use Copy Link, then paste it into PodLearn's + import.")
                    }
                    if type != UTType.plainText.identifier {
                        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ImportError.service("The shared item isn't a valid URL. Use Copy Link and paste it into PodLearn.") }
                        return try importSharedURL(url)
                    }
                    if let link = sharedLink(in: text) { return PendingImport(text: link) }
                    if fallback == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fallback = PendingImport(text: text) }
                } catch is CancellationError { throw CancellationError() }
                catch { if loadingError == nil { loadingError = error } }
            }
        }
        for text in items.compactMap({ $0.attributedContentText?.string }) {
            guard text.utf8.count <= 5_000_000 else { throw ImportError.tooLarge }
            if let link = sharedLink(in: text) { return PendingImport(text: link) }
            if fallback == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fallback = PendingImport(text: text) }
        }
        if let loadingError { throw loadingError }
        if let fallback { return fallback }
        throw ImportError.service("Share an Apple Podcasts or Bilibili link, English text, or a transcript file.")
    }

    private static func sharedURL(from provider: NSItemProvider) async throws -> URL {
        // Let Foundation decode its platform-specific NSURL archives rather than treating them as text.
        try await withCheckedThrowingContinuation { continuation in
            provider.loadObject(ofClass: URL.self) { url, error in
                if let error { continuation.resume(throwing: error) }
                else if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: ImportError.service("The source app returned no shared URL.")) }
            }
        }
    }

    private static func importSharedURL(_ url: URL) throws -> PendingImport {
        guard url.absoluteString.utf8.count <= 5_000_000 else { throw ImportError.tooLarge }
        if url.isFileURL { return try transcriptFile(url) }
        guard let link = sharedLink(in: url.absoluteString) else { throw ImportError.service("Share an Apple Podcasts episode or Bilibili link.") }
        return PendingImport(text: link)
    }

    private static func sharedData(from provider: NSItemProvider, type: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let error { continuation.resume(throwing: error) }
                else if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: ImportError.service("The source app returned no shared content.")) }
            }
        }
    }

    private static func sharedLink(in text: String) -> String? {
        if let link = try? BilibiliLink(text) { return link.url.absoluteString }
        if let link = try? EpisodeLink(text) { return link.url.absoluteString }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url else { continue }
            if let link = try? BilibiliLink(url.absoluteString) { return link.url.absoluteString }
            if let link = try? EpisodeLink(url.absoluteString) { return link.url.absoluteString }
        }
        return nil
    }

    private static func transcriptFile(_ url: URL) throws -> PendingImport {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard ["txt", "srt", "vtt"].contains(url.pathExtension.lowercased()) else { throw ImportError.service("Share a TXT, SRT, or VTT file.") }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 5_000_000 else { throw ImportError.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= 5_000_000 else { throw ImportError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw ImportError.service("The shared transcript file must contain UTF-8 text.") }
        return PendingImport(text: text, fileExtension: url.pathExtension, title: url.deletingPathExtension().lastPathComponent)
    }
}
