import Foundation

public enum SpeechService: String, CaseIterable, Sendable {
    case apple, openRouter
    public var label: String { self == .apple ? "Apple" : "OpenRouter" }
}

public enum SpeechCatalog {
    public struct Model: Decodable, Identifiable, Sendable {
        public let id: String
        public let name: String
        public let created: Int
        public let supportedVoices: [String]?
        let endpoints: [String]?
        enum CodingKeys: String, CodingKey {
            case id, name, created, endpoints
            case supportedVoices = "supported_voices"
        }
    }
    public struct Voice: Decodable, Identifiable, Sendable {
        public let id: String
        public let name: String
        public let previewURL: URL?
        enum CodingKeys: String, CodingKey {
            case id = "voice_id", name
            case previewURL = "preview_url"
        }
        public func matches(_ supportedVoice: String) -> Bool {
            id == supportedVoice || name.components(separatedBy: " - ")[0].caseInsensitiveCompare(supportedVoice) == .orderedSame
        }
        public var sampleURL: URL? {
            guard let previewURL, previewURL.scheme == "https", previewURL.host != nil,
                  previewURL.user == nil, previewURL.password == nil else { return nil }
            return previewURL
        }
    }
    public static func models(session: URLSession = .shared) async throws -> [Model] {
        struct Response: Decodable { let data: [Model] }
        let response: Response = try await load("https://openrouter.ai/api/v1/models?output_modalities=speech", session: session)
        var seen: Set<String> = []
        return response.data.filter {
            $0.id.hasPrefix("elevenlabs/") && $0.endpoints?.contains("/api/v1/audio/speech") == true && seen.insert($0.id).inserted
        }.sorted { $0.created == $1.created ? $0.name < $1.name : $0.created > $1.created }
    }
    public static func voices(session: URLSession = .shared) async throws -> [Voice] {
        struct Response: Decodable { let voices: [Voice] }
        let response: Response = try await load("https://api.elevenlabs.io/v1/voices", session: session)
        return response.voices
    }
    private static func load<T: Decodable>(_ url: String, session: URLSession) async throws -> T {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ImportError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ImportError.service("Speech catalog unavailable (HTTP \(http.statusCode)). Refresh to try again.")
        }
        guard data.count <= 5_000_000 else { throw ImportError.tooLarge }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
