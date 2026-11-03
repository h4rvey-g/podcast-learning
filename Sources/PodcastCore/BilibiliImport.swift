import Foundation
import CryptoKit
import Alamofire

public struct BilibiliLink: Sendable {
    public let url: URL
    public let id: String
    public let page: Int
    public var isAudio: Bool { id.hasPrefix("au") }
    public var isShort: Bool { url.host == "b23.tv" }
    public var episodeID: String { "bilibili:\(id):\(page)" }
    public init(_ input: String) throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let candidate = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.url
        guard let url = candidate ?? URL(string: text), url.scheme == "https",
              ["www.bilibili.com", "bilibili.com", "m.bilibili.com", "b23.tv"].contains(url.host?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.port == nil else { throw ImportError.invalidURL }
        let parts = url.path.split(separator: "/").map(String.init)
        if url.host?.lowercased() == "b23.tv" {
            guard parts.count == 1, parts[0].range(of: "^[a-zA-Z0-9]+$", options: .regularExpression) != nil else { throw ImportError.invalidURL }
            self.url = URL(string: "https://b23.tv/\(parts[0])")!; self.id = parts[0]; self.page = 1
            return
        }
        guard parts.count == 2, ["audio", "video"].contains(parts[0]) else { throw ImportError.invalidURL }
        let id = parts[1]
        let pattern = parts[0] == "audio" ? "^au[1-9][0-9]*$" : "^(BV[0-9A-Za-z]{10}|av[1-9][0-9]*)$"
        guard id.range(of: pattern, options: .regularExpression) != nil else { throw ImportError.invalidURL }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let p = query.first(where: { $0.name == "p" })?.value ?? "1"
        guard let page = Int(p), page > 0, !id.hasPrefix("au") || page == 1 else { throw ImportError.invalidURL }
        self.id = id; self.page = page
        self.url = URL(string: "https://www.bilibili.com/\(parts[0])/\(id)" + (page == 1 ? "" : "?p=\(page)"))!
    }
}

public struct BilibiliMedia: Sendable {
    public let link: BilibiliLink
    public let title: String
    public let author: String
    public let cover: String?
    public let duration: Double?
    public let audio: [URL]
    public let video: [URL]
}

public enum WBI {
    public static func query(_ parameters: [String: String], img: String, sub: String, timestamp: Int) throws -> String {
        let raw = Array(img + sub)
        guard raw.count == 64 else { throw ImportError.invalidResponse }
        let indices = [46,47,18,2,53,8,23,32,15,50,10,31,58,3,45,35,27,43,5,49,33,9,42,19,29,28,14,39,12,38,41,13]
        let key = String(indices.map { raw[$0] })
        var parameters = parameters; parameters["wts"] = String(timestamp)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let query = parameters.keys.sorted().map { name in
            let value = parameters[name]!.filter { !"!'()*".contains($0) }
            return name.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&")
        let signature = Insecure.MD5.hash(data: Data((query + key).utf8)).map { String(format: "%02x", $0) }.joined()
        return query + "&w_rid=" + signature
    }
}

public struct BilibiliClient {
    public static let headers: HTTPHeaders = ["User-Agent": "Mozilla/5.0", "Referer": "https://www.bilibili.com/"]
    private let session: Session
    public init(session: Session = ReliableTransfer.session) { self.session = session }
    private func get<T: Decodable & Sendable>(_ url: String, as: T.Type) async throws -> T {
        try await session.request(url, headers: Self.headers).validate(statusCode: 200..<300).serializingDecodable(T.self).value
    }
    public func expand(_ link: BilibiliLink) async throws -> BilibiliLink {
        guard link.isShort else { return link }
        let response = await session.request(link.url, method: .head, headers: Self.headers)
            .redirect(using: Redirector(behavior: .modify { _, request, _ in
                guard let url = request.url, url.scheme == "https",
                      ["b23.tv", "bilibili.com", "www.bilibili.com", "m.bilibili.com"].contains(url.host?.lowercased() ?? "") else { return nil }
                return request
            }))
            .validate(statusCode: 200..<300).serializingData().response
        _ = try response.result.get()
        guard let url = response.response?.url, let expanded = try? BilibiliLink(url.absoluteString), !expanded.isShort else {
            throw ImportError.service("This Bilibili short link couldn't be opened. Paste the full video or audio link instead.")
        }
        return expanded
    }
    public func resolve(_ input: BilibiliLink, includeVideo: Bool = false) async throws -> BilibiliMedia {
        let link = try await expand(input)
        if link.isAudio {
            let info = try await get("https://www.bilibili.com/audio/music-service-c/web/song/info?sid=\(link.id.dropFirst(2))", as: Envelope<Song>.self).checked()
            let result = try await get("https://www.bilibili.com/audio/music-service-c/web/url?sid=\(link.id.dropFirst(2))&quality=2&privilege=2", as: Envelope<Audio>.self)
            let audio = try result.checked()
            guard audio.type != -1 else { throw ImportError.service("Bilibili only returned a paid preview. Choose a freely available full recording.") }
            let urls = Self.urls(audio.cdns)
            guard !urls.isEmpty else { throw ImportError.invalidResponse }
            return BilibiliMedia(link: link, title: info.title, author: info.author.isEmpty ? info.uname : info.author,
                                 cover: info.cover, duration: info.duration, audio: urls, video: [])
        }
        let identity = link.id.hasPrefix("BV") ? "bvid=\(link.id)" : "aid=\(link.id.dropFirst(2))"
        let info = try await get("https://api.bilibili.com/x/web-interface/view?\(identity)", as: Envelope<Video>.self).checked()
        guard let page = info.pages.first(where: { $0.page == link.page }) else { throw ImportError.service("This video part is unavailable.") }
        guard info.is_upower_exclusive != true, info.is_upower_preview != true else {
            throw ImportError.service("Paid or preview-only videos aren't supported. Choose a freely available video.")
        }
        let nav = try await get("https://api.bilibili.com/x/web-interface/nav", as: Envelope<Navigation>.self)
        guard let keys = nav.data?.wbi_img else { throw ImportError.invalidResponse }
        func key(_ value: String) -> String { URL(string: value)?.deletingPathExtension().lastPathComponent ?? "" }
        let query = try WBI.query(["bvid": info.bvid, "cid": String(page.cid), "fnval": "16", "fnver": "0", "qn": "32"],
                                  img: key(keys.img_url), sub: key(keys.sub_url), timestamp: Int(Date().timeIntervalSince1970))
        let play = try await get("https://api.bilibili.com/x/player/wbi/playurl?\(query)", as: Envelope<Playback>.self).checked()
        guard play.is_preview != true, play.trial_info == nil else { throw ImportError.service("Bilibili returned a preview, not the full recording.") }
        guard let dash = play.dash,
              let audio = dash.audio?.filter({ $0.mimeType == "audio/mp4" || $0.mime_type == "audio/mp4" })
                .max(by: { ($0.bandwidth ?? 0) < ($1.bandwidth ?? 0) }), !audio.urls.isEmpty else {
            throw ImportError.service("No accessible audio track was found. Login-restricted videos aren't supported.")
        }
        let video = includeVideo ? dash.video?.filter({ ($0.codecs ?? "").hasPrefix("avc") })
            .min(by: { ($0.bandwidth ?? 0) < ($1.bandwidth ?? 0) })?.urls ?? [] : []
        if includeVideo && video.isEmpty { throw ImportError.service("No downloadable video track was found. Turn off Keep Video in Settings to import audio only.") }
        return BilibiliMedia(link: link, title: info.title + (info.pages.count > 1 ? " · \(page.part)" : ""),
                             author: info.owner.name, cover: info.pic, duration: page.duration, audio: audio.urls, video: video)
    }
    private static func urls(_ values: [String]) -> [URL] {
        values.compactMap { value in
            guard let url = URL(string: value.hasPrefix("//") ? "https:" + value : value), url.scheme == "https", url.host != nil else { return nil }
            return url
        }
    }
    private struct Envelope<T: Decodable & Sendable>: Decodable, Sendable {
        let code: Int; let data: T?
        func checked() throws -> T {
            guard code == 0, let data else { throw ImportError.service("Bilibili couldn't provide this recording (code \(code)). It may be unavailable or require login.") }
            return data
        }
    }
    private struct Audio: Decodable, Sendable { let type: Int; let cdns: [String] }
    private struct Song: Decodable, Sendable { let title: String; let author: String; let uname: String; let cover: String?; let duration: Double }
    private struct Video: Decodable, Sendable {
        let bvid: String; let title: String; let pic: String?; let owner: Owner; let pages: [Page]
        let is_upower_exclusive: Bool?; let is_upower_preview: Bool?
        struct Owner: Decodable, Sendable { let name: String }
        struct Page: Decodable, Sendable { let cid: Int64; let page: Int; let part: String; let duration: Double }
    }
    private struct Navigation: Decodable, Sendable {
        let wbi_img: Keys
        struct Keys: Decodable, Sendable { let img_url: String; let sub_url: String }
    }
    private struct Playback: Decodable, Sendable {
        let dash: Dash?; let is_preview: Bool?; let trial_info: Trial?
        struct Trial: Decodable, Sendable {}
        struct Dash: Decodable, Sendable { let audio: [Track]?; let video: [Track]? }
        struct Track: Decodable, Sendable {
            let baseUrl: String?; let base_url: String?; let backupUrl: [String]?; let backup_url: [String]?
            let mimeType: String?; let mime_type: String?; let bandwidth: Int?; let codecs: String?
            var urls: [URL] { BilibiliClient.urls([baseUrl ?? base_url ?? ""] + (backupUrl ?? backup_url ?? [])) }
        }
    }
}
