import Foundation
import Alamofire

// Speech's synchronous POST has no resumable job ID: a lost response requires replaying the upload.
public final class TransferRetryPolicy: RetryPolicy, @unchecked Sendable {
    public init(retryLimit: UInt = 5, scale: Double = 1) {
        super.init(retryLimit: retryLimit, exponentialBackoffScale: scale,
                   retryableHTTPMethods: [.get, .post], retryableHTTPStatusCodes: [408, 429, 500, 502, 503, 504])
    }
    public override func retry(_ request: Request, for session: Session, dueTo error: Error,
                               completion: @escaping @Sendable (RetryResult) -> Void) {
        guard request.retryCount < retryLimit, shouldRetry(request: request, dueTo: error) else {
            completion(.doNotRetry); return
        }
        let backoff = pow(Double(exponentialBackoffBase), Double(request.retryCount)) * exponentialBackoffScale
        let serverDelay = request.response?.value(forHTTPHeaderField: "Retry-After").flatMap(Self.retryAfter) ?? 0
        guard serverDelay <= 3600 else { completion(.doNotRetry); return }
        completion(.retryWithDelay(max(backoff, serverDelay)))
    }
    public static func retryAfter(_ value: String) -> TimeInterval? {
        if let seconds = Double(value), seconds.isFinite { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }
}

public enum ReliableTransfer {
    public static let session: Session = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 86_400
        config.urlCache = nil
        config.httpCookieStorage = nil
        return Session(configuration: config, interceptor: TransferRetryPolicy())
    }()
    public static func download(_ urls: [URL], to destination: URL, headers: HTTPHeaders = [:],
                                session: Session = session,
                                progress: @escaping @Sendable (Double?) -> Void = { _ in }) async throws {
        guard !urls.isEmpty, urls.allSatisfy({ $0.scheme == "https" && $0.host != nil }) else { throw ImportError.invalidURL }
        var lastError: Error = ImportError.invalidResponse
        for url in urls {
            try Task.checkCancellation()
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".partial")
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let request = session.download(url, headers: headers, to: { _, _ in (temporary, [.removePreviousFile]) })
                    .validate(statusCode: 200..<300)
                    .downloadProgress { progress($0.totalUnitCount > 0 ? $0.fractionCompleted : nil) }
                let response = await request.serializingDownloadedFileURL().response
                let file = try response.result.get()
                let mime = response.response?.mimeType ?? ""
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0 else { throw ImportError.service("Media download returned an empty file.") }
                guard !mime.contains("text"), !mime.contains("json") else {
                    throw ImportError.service("Media download returned text/JSON instead of audio/video (HTTP \(response.response?.statusCode ?? 0)). The source may require sign-in or the media link may have expired.")
                }
                try commit(file, to: destination)
                return
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
            }
        }
        throw lastError
    }
    public static func commit(_ temporary: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: destination) }
        var url = destination, values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
