import Foundation

public struct AudioStore {
    public static func directory() throws -> URL {
        let url = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    public static func file(_ id: UUID) throws -> URL { try directory().appendingPathComponent(id.uuidString + ".mp3") }
    public static func localURL(_ id: UUID) -> URL? {
        guard let url = try? file(id), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
    public static func size(_ id: UUID) -> Int64 {
        guard let url = localURL(id), let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
    public static func download(_ remote: URL, id: UUID, session: URLSession = .shared, progress: @escaping @Sendable (Double?) -> Void = { _ in }) async throws {
        guard ["https", "http"].contains(remote.scheme) else { throw ImportError.invalidURL }
        let (temporary, response) = try await session.download(from: remote, delegate: AudioDownloadProgress(report: progress))
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !(http.mimeType ?? "").contains("text"), !(http.mimeType ?? "").contains("json") else { throw ImportError.invalidResponse }
        let destination = try file(id)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: destination) }
        var url = destination, values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    public static func delete(_ id: UUID) throws {
        if let url = localURL(id) { try FileManager.default.removeItem(at: url) }
    }
}

// One synchronous task-creation callback installs the observation before this task starts.
private final class AudioDownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let report: @Sendable (Double?) -> Void
    private var observation: NSKeyValueObservation?
    init(report: @escaping @Sendable (Double?) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        observation = task.observe(\.countOfBytesReceived, options: [.initial, .new]) { [report] task, _ in
            let total = task.countOfBytesExpectedToReceive
            report(total > 0 ? min(1, max(0, Double(task.countOfBytesReceived) / Double(total))) : nil)
        }
    }
}

public struct PlaybackRange: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public init?(start: Double, end: Double) {
        guard start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
        self.start = start; self.end = end
    }
    public func time(at fraction: Double) -> Double { start + (end - start) * (fraction.isFinite ? max(0, min(1, fraction)) : 0) }
    public func fraction(at time: Double) -> Double { time.isFinite ? max(0, min(1, (time - start) / (end - start))) : 0 }
}
