import Foundation
import Security
import Observation
import PodcastCore

@Observable final class SettingsStore {
    var targetLevel: String { didSet { defaults.set(targetLevel, forKey: "targetLevel") } }
    var host: String { didSet { defaults.set(host, forKey: "aiHost") } }
    var basePath: String { didSet { defaults.set(basePath, forKey: "aiBasePath") } }
    var model: String { didSet { defaults.set(model, forKey: "aiModel") } }
    var voice: String { didSet { defaults.set(voice, forKey: "voice") } }
    var rate: Double { didSet { defaults.set(rate, forKey: "rate") } }
    var aiConsent: Bool { didSet { defaults.set(aiConsent, forKey: "aiConsent") } }
    let uid: String
    private let defaults = UserDefaults.standard
    init() {
        targetLevel = defaults.string(forKey: "targetLevel") ?? "B2"
        host = defaults.string(forKey: "aiHost") ?? "api.openai.com"
        basePath = defaults.string(forKey: "aiBasePath") ?? "/v1"
        model = defaults.string(forKey: "aiModel") ?? "gpt-4.1"
        voice = defaults.string(forKey: "voice") ?? "en-US"
        rate = defaults.object(forKey: "rate") as? Double ?? 0.45
        aiConsent = defaults.bool(forKey: "aiConsent")
        uid = defaults.string(forKey: "podTextUID") ?? UUID().uuidString
        defaults.set(uid, forKey: "podTextUID")
    }
    var level: CEFR { CEFR(rawValue: targetLevel) ?? .b2 }
}

enum APIKey {
    static let service = "PodcastLearning.AI"
    static func read() throws -> String {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw failure(status) }
        return value
    }
    static func save(_ value: String) throws {
        if value.isEmpty {
            let status = SecItemDelete(baseQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(query as CFDictionary, nil)
            guard result == errSecSuccess else { throw failure(result) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    private static var baseQuery: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "apiKey"] }
    private static func failure(_ code: OSStatus) -> NSError { NSError(domain: NSOSStatusErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Keychain access failed (\(code)). Unlock your device and try again."]) }
}
