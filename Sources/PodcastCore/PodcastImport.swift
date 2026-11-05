import Foundation

public struct EpisodeLink: Sendable {
    public let showID: String
    public let episodeID: String
    public let url: URL
    public init(_ value: String) throws {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host?.lowercased() == "podcasts.apple.com",
              let idRange = url.path.range(of: "id[0-9]+", options: .regularExpression),
              let episode = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "i" })?.value,
              !episode.isEmpty, episode.allSatisfy(\.isNumber) else { throw ImportError.invalidURL }
        self.url = url; showID = String(url.path[idRange].dropFirst(2)); episodeID = episode
    }
}

public struct PodTextResponse: Decodable, Sendable {
    public let success: Bool
    public let data: Episode?
    public let error: String?
    public struct Episode: Decodable, Sendable {
        public let id: String
        public let title: String
        public let author: String
        public let cover: String?
        public let segments: [Paragraph]
    }
    public struct Paragraph: Decodable, Sendable {
        public let speaker: String?
        public let startSeconds: Double?
        public let endSeconds: Double?
        public let text: String
    }
    fileprivate var failureReason: String? {
        guard let message = error?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else { return nil }
        if message.localizedCaseInsensitiveContains("Apple Media Token has expired") {
            return "Apple Podcasts access has expired on PodText. PodText needs to restore its service. Try again later or import a transcript file."
        }
        return message
    }
    @MainActor public func transcript() throws -> Transcript {
        guard success, let data else { throw ImportError.service("PodText: \(failureReason ?? "No transcript was found. Try importing text instead.")") }
        guard !data.segments.isEmpty else { throw ImportError.emptyText }
        let transcript = Transcript(title: data.title, author: data.author)
        transcript.episodeID = data.id; transcript.coverURL = data.cover
        var index = 0
        transcript.segments = data.segments.enumerated().compactMap { offset, paragraph in
            guard !paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let segment = Segment(index: offset, text: paragraph.text, speaker: paragraph.speaker,
                                  start: paragraph.startSeconds, end: paragraph.endSeconds)
            segment.sentences = TextImporter.sentences(paragraph.text).map {
                defer { index += 1 }; return Sentence(index: index, text: $0)
            }
            return segment
        }
        guard !(transcript.segments ?? []).isEmpty else { throw ImportError.emptyText }
        return transcript
    }
}

public enum HTTP {
    public static func data(for request: URLRequest, session: URLSession = .shared) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw ImportError.service("The service could not complete this request. Try again later.")
        }
        guard data.count <= 25_000_000 else { throw ImportError.tooLarge }
        return data
    }
}

public struct PodTextClient {
    public init() {}
    public func fetch(_ link: EpisodeLink, uid: String, session: URLSession = .shared) async throws -> PodTextResponse {
        var request = URLRequest(url: URL(string: "https://pod-text.com/api/transcript")!)
        request.httpMethod = "POST"; request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["url": link.url.absoluteString, "uid": uid])
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ImportError.invalidResponse }
        guard data.count <= 25_000_000 else { throw ImportError.tooLarge }
        guard (200..<300).contains(response.statusCode) else {
            let failure = try? JSONDecoder().decode(PodTextResponse.self, from: data)
            let reason = failure?.success == false ? failure?.failureReason : nil
            throw ImportError.service("PodText (HTTP \(response.statusCode)): \(reason ?? "The transcript service is unavailable. Try again later or import a transcript file.")")
        }
        return try JSONDecoder().decode(PodTextResponse.self, from: data)
    }
}

public struct RSSItem: Equatable, Sendable {
    public var title: String = ""
    public var guid: String = ""
    public var audioURL: URL?
}

public final class RSSParser: NSObject, XMLParserDelegate {
    private var items: [RSSItem] = []
    private var item: RSSItem?
    private var element = ""
    public static func parse(_ data: Data) throws -> [RSSItem] {
        let delegate = RSSParser(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw ImportError.invalidResponse }
        return delegate.items
    }
    public func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        element = elementName
        if elementName == "item" { item = RSSItem() }
        if elementName == "enclosure", let url = attributes["url"] { item?.audioURL = URL(string: url) }
    }
    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        if element == "title" { item?.title += string }
        if element == "guid" { item?.guid += string }
    }
    public func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: string) }
    }
    public func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "item", let item { items.append(item); self.item = nil }
        element = ""
    }
}

public struct ITunesResponse: Decodable, Sendable {
    public let results: [Entry]
    public struct Entry: Decodable, Sendable {
        public let trackId: Int64?
        public let episodeUrl: String?
        public let episodeGuid: String?
        public let feedUrl: String?
        public let trackTimeMillis: Double?
    }
}

public struct EpisodeAudio: Sendable {
    public let url: URL
    public let duration: Double?
}

public enum AudioResolver {
    @MainActor public static func preview(_ link: EpisodeLink, session: URLSession = .shared) async throws -> Transcript {
        let data = try await HTTP.data(for: URLRequest(url: link.url), session: session)
        guard let html = String(data: data, encoding: .utf8) else { throw ImportError.invalidResponse }
        // shortcut: reads Apple's public episode payload; update this parser if its page format changes.
        let pattern = #"<script\b[^>]*\bid\s*=\s*["']serialized-server-data["'][^>]*>([\s\S]*?)</script\s*>"#
        let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        guard let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { throw ImportError.invalidResponse }
        let page = try JSONSerialization.jsonObject(with: Data(html[range].utf8))
        func episodeOffer(in value: Any) -> [String: Any]? {
            if let object = value as? [String: Any] {
                if object["contentId"] as? String == link.episodeID,
                   let show = object["showOffer"] as? [String: Any], show["adamId"] as? String == link.showID,
                   object["priceType"] as? String == "STDQ", object["streamUrl"] is String { return object }
                for child in object.values { if let offer = episodeOffer(in: child) { return offer } }
            } else if let array = value as? [Any] {
                for child in array { if let offer = episodeOffer(in: child) { return offer } }
            }
            return nil
        }
        guard let offer = episodeOffer(in: page), let title = offer["title"] as? String,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let value = offer["streamUrl"] as? String, let audio = URL(string: value),
              ["https", "http"].contains(audio.scheme), audio.host != nil, audio.user == nil, audio.password == nil else {
            throw ImportError.service("No public episode audio was found on Apple Podcasts. Check the episode link or import a transcript file.")
        }
        let show = offer["showOffer"] as? [String: Any]
        let transcript = Transcript(title: title, author: show?["title"] as? String ?? "")
        transcript.episodeID = link.episodeID; transcript.sourceURL = link.url.absoluteString
        transcript.remoteAudioURL = audio.absoluteString
        if let duration = offer["duration"] as? Double, duration.isFinite, duration > 0 { transcript.audioDuration = duration }
        let artwork = (offer["episodeArtwork"] as? [String: Any]) ?? (offer["artwork"] as? [String: Any])
        transcript.coverURL = (artwork?["template"] as? String)?.replacingOccurrences(of: "{w}", with: "600")
            .replacingOccurrences(of: "{h}", with: "600").replacingOccurrences(of: "{f}", with: "jpg")
        return transcript
    }
    public static func normalizedTitle(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    public static func match(_ items: [RSSItem], guid: String?, title: String) -> URL? {
        if let guid, let match = items.first(where: { $0.guid.trimmingCharacters(in: .whitespacesAndNewlines) == guid }) { return match.audioURL }
        return items.first { normalizedTitle($0.title) == normalizedTitle(title) }?.audioURL
    }
    public static func resolve(_ link: EpisodeLink, title: String, session: URLSession = .shared) async throws -> EpisodeAudio? {
        let url = URL(string: "https://itunes.apple.com/lookup?id=\(link.showID)&entity=podcastEpisode&limit=200")!
        let lookup = try JSONDecoder().decode(ITunesResponse.self, from: await HTTP.data(for: URLRequest(url: url), session: session))
        let episode = lookup.results.first { String($0.trackId ?? 0) == link.episodeID }
        let duration = episode?.trackTimeMillis.flatMap { $0.isFinite && $0 > 0 ? $0 / 1000 : nil }
        if let value = episode?.episodeUrl, let url = URL(string: value), url.scheme == "https" { return EpisodeAudio(url: url, duration: duration) }
        guard let feed = lookup.results.compactMap(\.feedUrl).first, let feedURL = URL(string: feed), ["https", "http"].contains(feedURL.scheme) else { return nil }
        let data = try await HTTP.data(for: URLRequest(url: feedURL), session: session)
        return try match(RSSParser.parse(data), guid: episode?.episodeGuid, title: title).map { EpisodeAudio(url: $0, duration: duration) }
    }
}
