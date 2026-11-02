import Foundation

public struct PendingImport: Codable, Sendable {
    public let text: String
    public let fileExtension: String
    public let title: String
    public init(text: String, fileExtension: String = "txt", title: String = "Shared transcript") {
        self.text = text; self.fileExtension = fileExtension; self.title = title
    }
}
