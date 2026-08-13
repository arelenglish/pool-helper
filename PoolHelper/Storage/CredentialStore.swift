import Foundation
import Security

/// Stores the one account's credentials in the Keychain.
///
/// iAqualink issues no scoped or per-device tokens, so whatever lives here is full account
/// access. On a shared iPad that makes the storage attributes the main line of defense:
/// `.whenUnlockedThisDeviceOnly` keeps the item off backups and out of iCloud, so it cannot
/// escape the device it was entered on.
nonisolated struct CredentialStore {
    private static let service = "com.poolhelper.iaqualink"
    private static let account = "primary"

    nonisolated struct Credentials: Equatable, Sendable {
        var email: String
        var password: String
    }

    static func save(_ credentials: Credentials) throws {
        let payload = try JSONEncoder().encode([credentials.email, credentials.password])

        // Delete-then-add rather than update: it is one code path and cannot leave a stale
        // item behind if the attributes ever change.
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ] as CFDictionary)

        let status = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: payload,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ] as CFDictionary, nil)

        guard status == errSecSuccess else {
            throw PoolError.badResponse("keychain write failed (\(status))")
        }
    }

    static func load() -> Credentials? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &item)

        guard status == errSecSuccess,
              let data = item as? Data,
              let parts = try? JSONDecoder().decode([String].self, from: data),
              parts.count == 2
        else { return nil }

        return Credentials(email: parts[0], password: parts[1])
    }

    static func clear() {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ] as CFDictionary)
    }
}

/// Indirection so `PoolStore` can be tested without touching the real Keychain, which is
/// unavailable to unit tests and shared across runs.
nonisolated struct CredentialProvider: Sendable {
    var load: @Sendable () -> CredentialStore.Credentials?
    var save: @Sendable (CredentialStore.Credentials) throws -> Void
    var clear: @Sendable () -> Void

    static let keychain = CredentialProvider(
        load: { CredentialStore.load() },
        save: { try CredentialStore.save($0) },
        clear: { CredentialStore.clear() }
    )

    static func inMemory(_ initial: CredentialStore.Credentials? = nil) -> CredentialProvider {
        let box = Box(initial)
        return CredentialProvider(
            load: { box.value },
            save: { box.value = $0 },
            clear: { box.value = nil }
        )
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: CredentialStore.Credentials?
        init(_ value: CredentialStore.Credentials?) { stored = value }
        var value: CredentialStore.Credentials? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}
