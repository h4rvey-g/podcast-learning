import Foundation

public struct PendingImport: Codable, Sendable {
    public let text: String
    public let fileExtension: String
    public let title: String
    public init(text: String, fileExtension: String = "txt", title: String = "Shared transcript") {
        self.text = text; self.fileExtension = fileExtension; self.title = title
    }
    public static func appGroupIdentifier(in bundle: Bundle) -> String? {
        let profile = bundle.url(forResource: "embedded", withExtension: "mobileprovision")
            .flatMap { try? Data(contentsOf: $0) }
        return appGroupIdentifier(in: bundle.infoDictionary ?? [:], provisioningProfile: profile)
    }
    public static func appGroupIdentifier(in info: [String: Any], provisioningProfile: Data? = nil) -> String? {
        guard let configured = info["AppGroupIdentifier"] as? String, !configured.isEmpty else { return nil }
        // SideStore can rename App Groups without publishing ALTAppGroups; prefer the installed profile.
        let signedGroups = (provisionedAppGroups(in: provisioningProfile) ?? []) + (info["ALTAppGroups"] as? [String] ?? [])
        return signedGroups.first { $0 == configured || $0.hasPrefix(configured + ".") } ?? configured
    }
    public static func appGroupDiagnostics(in info: [String: Any], provisioningProfile: Data?) -> String {
        let installerGroups = info["ALTAppGroups"] as? [String] ?? []
        var profileGroups = provisioningProfile == nil ? "profile unavailable" : "profile unreadable"
        if let groups = provisionedAppGroups(in: provisioningProfile) {
            profileGroups = groups.isEmpty ? "none" : groups.joined(separator: ", ")
        }
        return """
        Share signing diagnostics 3
        Bundle: \(info["CFBundleIdentifier"] as? String ?? "missing")
        Configured: \(info["AppGroupIdentifier"] as? String ?? "missing")
        Selected: \(appGroupIdentifier(in: info, provisioningProfile: provisioningProfile) ?? "none")
        Installer groups: \(installerGroups.isEmpty ? "none" : installerGroups.joined(separator: ", "))
        Profile groups: \(profileGroups)
        """
    }
    private static func provisionedAppGroups(in data: Data?) -> [String]? {
        // The profile resolves the name only; iOS still enforces the process's actual container entitlement.
        guard let data,
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return nil }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }
}
