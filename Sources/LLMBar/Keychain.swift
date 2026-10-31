import Foundation
import Security

// The Jev (TypeSafe) API key lives in the login keychain as a generic password. The app checks
// for it by ATTRIBUTES only (no secret is read, so no keychain prompt), never shows it, and on
// save updates the existing item instead of adding a duplicate.

enum JevKey {
    /// Service names the key may already live under, in priority order.
    static let services = ["JEV_API_KEY", "TYPESAFE_API_KEY"]

    /// The service holding the key, if any. Attributes only: the secret is never read here.
    static func existingService() -> String? {
        for service in services {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var out: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess { return service }
        }
        return nil
    }

    enum SaveError: Error, CustomStringConvertible {
        case empty, whitespace, doubled, keychain(OSStatus)
        var description: String {
            switch self {
            case .empty: return "The key is empty."
            case .whitespace: return "The key contains spaces or line breaks."
            case .doubled: return "That looks like the key pasted twice. Paste it once."
            case .keychain(let s): return (SecCopyErrorMessageString(s, nil) as String?) ?? "Keychain error \(s)."
            }
        }
    }

    /// Saves the key: updates the existing item (whichever service holds it) or adds JEV_API_KEY.
    static func save(_ raw: String) -> Result<String, SaveError> {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return .failure(.empty) }
        if key.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { return .failure(.whitespace) }
        if key.count % 2 == 0 {
            let half = key.index(key.startIndex, offsetBy: key.count / 2)
            if key[..<half] == key[half...] { return .failure(.doubled) }
        }
        let data = Data(key.utf8)
        if let service = existingService() {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            return status == errSecSuccess ? .success(service) : .failure(.keychain(status))
        }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: services[0],
            kSecAttrAccount as String: NSUserName(),
            kSecAttrLabel as String: services[0],
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        return status == errSecSuccess ? .success(services[0]) : .failure(.keychain(status))
    }
}
