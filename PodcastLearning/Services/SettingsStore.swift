import Foundation
import Security
import Observation
import AVFoundation
import PodcastCore

@Observable final class SettingsStore {
    var targetLevel: String { didSet { defaults.set(targetLevel, forKey: "targetLevel") } }
    var baseURL: String { didSet { defaults.set(baseURL, forKey: "aiBaseURL") } }
    var model: String { didSet { defaults.set(model, forKey: "aiModel") } }
    var aiAPI: String { didSet { defaults.set(aiAPI, forKey: "aiAPI") } }
    var thinking: String { didSet { defaults.set(thinking, forKey: "thinking") } }
    var speechModel: String { didSet { defaults.set(speechModel, forKey: "speechModel") } }
    var voice: String { didSet { defaults.set(voice, forKey: "voice") } }
    var rate: Double { didSet { defaults.set(rate, forKey: "rate") } }
    var aiConsent: Bool { didSet { defaults.set(aiConsent, forKey: "aiConsent") } }
    var speechEndpoint: String { didSet { defaults.set(speechEndpoint, forKey: "speechEndpoint") } }
    var transcriptionConsent: Bool { didSet { defaults.set(transcriptionConsent, forKey: "transcriptionConsent") } }
    var keepBilibiliVideo: Bool { didSet { defaults.set(keepBilibiliVideo, forKey: "keepBilibiliVideo") } }
    let uid: String
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        targetLevel = defaults.string(forKey: "targetLevel") ?? "B2"
        baseURL = defaults.string(forKey: "aiBaseURL") ?? "https://\(defaults.string(forKey: "aiHost") ?? "api.openai.com")\(defaults.string(forKey: "aiBasePath") ?? "/v1")"
        model = defaults.string(forKey: "aiModel") ?? "gpt-4.1"
        aiAPI = defaults.string(forKey: "aiAPI") ?? "chat"
        thinking = defaults.string(forKey: "thinking") ?? "provider-default"
        speechModel = defaults.string(forKey: "speechModel") ?? "MAI-Transcribe-2"
        voice = defaults.string(forKey: "voice") ?? "en-US"
        rate = defaults.object(forKey: "rate") as? Double ?? 0.45
        aiConsent = defaults.bool(forKey: "aiConsent")
        speechEndpoint = defaults.string(forKey: "speechEndpoint") ?? ""
        transcriptionConsent = defaults.bool(forKey: "transcriptionConsent")
        keepBilibiliVideo = defaults.bool(forKey: "keepBilibiliVideo")
        uid = defaults.string(forKey: "podTextUID") ?? UUID().uuidString
        defaults.set(uid, forKey: "podTextUID")
    }
    var speechVoice: AVSpeechSynthesisVoice? { AVSpeechSynthesisVoice(identifier: voice) ?? AVSpeechSynthesisVoice(language: voice) ?? AVSpeechSynthesisVoice(language: "en-US") }
    var level: CEFR { CEFR(rawValue: targetLevel) ?? .b2 }
}

enum APIKey {
    static let service = "PodcastLearning.AI"
    static func read(account: String = "apiKey") throws -> String {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw failure(status) }
        return value
    }
    static func save(_ value: String, account: String = "apiKey") throws {
        if value.isEmpty {
            let status = SecItemDelete(baseQuery(account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery(account)
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(query as CFDictionary, nil)
            guard result == errSecSuccess else { throw failure(result) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    private static func baseQuery(_ account: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] }
    private static func failure(_ code: OSStatus) -> NSError { NSError(domain: NSOSStatusErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Keychain access failed (\(code)). Unlock your device and try again."]) }
}
