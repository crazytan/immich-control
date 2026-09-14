import Foundation
import Security

/// The small, named set of credentials used by the existing backup repositories.
///
/// Values deliberately remain in the user's login keychain. They are never copied
/// into `ImmichConfiguration`, launchd plists, process arguments, or logs.
public enum BackupSecret: String, CaseIterable, Sendable {
    case resticPassword = "immich-restic-password"
    case r2AccessKeyID = "immich-r2-access-key-id"
    case r2SecretAccessKey = "immich-r2-secret-access-key"
}

public enum KeychainStoreError: LocalizedError, Equatable {
    case itemNotFound(service: String, account: String)
    case invalidUTF8(service: String, account: String)
    case unexpectedStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case let .itemNotFound(service, account):
            return "No Keychain item exists for \(service) (account \(account))."
        case let .invalidUTF8(service, account):
            return "The Keychain item for \(service) (account \(account)) is not valid text."
        case let .unexpectedStatus(status):
            return "Keychain operation failed (\(status))."
        }
    }
}

public protocol SecretStoring: Sendable {
    func read(service: String, account: String) throws -> String
    func write(_ value: String, service: String, account: String) throws
    func delete(service: String, account: String) throws
}

/// Secure access to generic-password items. The legacy scripts used account
/// `immich-backup`; retaining it means existing secrets work without migration.
public struct KeychainStore: SecretStoring, Sendable {
    public static let legacyAccount = "immich-backup"

    public init() {}

    public func read(secret: BackupSecret, account: String = KeychainStore.legacyAccount) throws -> String {
        try read(service: secret.rawValue, account: account)
    }

    public func write(_ value: String, secret: BackupSecret, account: String = KeychainStore.legacyAccount) throws {
        try write(value, service: secret.rawValue, account: account)
    }

    public func read(service: String, account: String) throws -> String {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else {
            throw KeychainStoreError.itemNotFound(service: service, account: account)
        }
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.invalidUTF8(service: service, account: account)
        }
        return value
    }

    public func write(_ value: String, service: String, account: String) throws {
        let match: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(match as CFDictionary, [kSecValueData: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(updateStatus)
        }
        var add = match
        add[kSecValueData] = data
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(addStatus)
        }
    }

    public func delete(service: String, account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }
}
