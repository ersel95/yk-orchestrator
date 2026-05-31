import Foundation
import Security

/// Hassas değerleri (Jira PAT, Bitbucket HTTP token) macOS Keychain'e yazar.
/// `readAllAsEnv()` SidecarManager tarafından çağrılarak backend'e ENV ile geçilir.
final class KeychainStore {

    static let shared = KeychainStore()

    private let service = "com.yapikredi.ykorchestrator"

    /// Anahtar → backend ENV adı eşleşmesi.
    /// LLM provider key'leri: provider id'leriyle uyumlu — backend
    /// app.core.config.Settings içinde ENV'den okunup ProviderConfig.api_key'e
    /// inject edilir.
    private let knownKeys: [(key: String, env: String)] = [
        ("jira_api_token",         "JIRA_API_TOKEN"),
        ("bitbucket_app_password", "BITBUCKET_APP_PASSWORD"),
        ("llm_api_key",            "LLM_API_KEY"),
        ("anthropic_api_key",      "ANTHROPIC_API_KEY"),
        ("openai_api_key",         "OPENAI_API_KEY"),
    ]

    // MARK: - Public API

    func set(_ value: String, for key: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.osStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.osStatus(updateStatus)
        }
    }

    func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Bilinen tüm anahtarları ENV name → value şeklinde döner.
    /// SidecarManager bunu Process.environment'a inject eder.
    func readAllAsEnv() -> [String: String] {
        var env: [String: String] = [:]
        for entry in knownKeys {
            if let v = get(entry.key), !v.isEmpty {
                env[entry.env] = v
            }
        }
        return env
    }

    // MARK: - Errors

    enum KeychainError: Error, LocalizedError {
        case osStatus(OSStatus)
        var errorDescription: String? {
            switch self {
            case .osStatus(let s): return "Keychain hatası: OSStatus \(s)"
            }
        }
    }
}
