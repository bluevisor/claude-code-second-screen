// Plan label derivation. Claude Code stores the OAuth blob (including
// subscriptionType + rateLimitTier) in the macOS Keychain under the generic
// password service "Claude Code-credentials". We read it once per session
// and translate the tier into the screen label.

import Foundation
import Security

enum ClaudePlan {
    /// Best-effort plan label. Falls back to "API USAGE" if the keychain
    /// blob isn't present (Claude Code may be using a raw API key or have
    /// never been signed in on this machine).
    static func detect() -> String {
        guard let blob = readKeychainBlob(service: "Claude Code-credentials"),
              let json = try? JSONSerialization.jsonObject(with: blob) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any]
        else { return "API USAGE" }
        let tier = (oauth["rateLimitTier"] as? String ?? "").lowercased()
        let sub = (oauth["subscriptionType"] as? String ?? "").lowercased()
        if tier.contains("max_20x") || tier.contains("max20") { return "MAX 20×" }
        if tier.contains("max_5x")  || tier.contains("max5")  { return "MAX 5×" }
        if tier.contains("team") || sub.contains("team")      { return "TEAM" }
        if tier.contains("pro")  || sub.contains("pro")       { return "PRO" }
        if sub.contains("max") { return "MAX" }
        return "API USAGE"
    }

    private static func readKeychainBlob(service: String) -> Data? {
        // Account is unset — matches any account under this service.
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }
}
