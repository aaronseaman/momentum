import Foundation
import CryptoKit
import Security
import MomentumKit

enum StorageError: Error, LocalizedError {
    case keychain(OSStatus)
    case sealing

    var errorDescription: String? {
        switch self {
        case .keychain(let status): "Keychain error \(status)."
        case .sealing: "Couldn't encrypt your data."
        }
    }
}

/// Thin Keychain wrapper. Items are available after first unlock so background refresh works.
enum Keychain {
    static let service = "app.momentum"

    private static func baseQuery(_ account: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        #if os(macOS)
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return query
    }

    /// Runs `body` against the modern data-protection keychain, falling back to the
    /// legacy macOS keychain for unsigned/dev builds that lack the entitlement.
    private static func withFallback(_ body: (Bool) -> OSStatus) -> OSStatus {
        let status = body(true)
        #if os(macOS)
        if status == errSecMissingEntitlement { return body(false) }
        #endif
        return status
    }

    static func set(_ data: Data, account: String) throws {
        let status = withFallback { dp in
            let query = baseQuery(account, dataProtection: dp)
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ]
            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var add = query
                add.merge(attributes) { $1 }
                status = SecItemAdd(add as CFDictionary, nil)
            }
            return status
        }
        guard status == errSecSuccess else { throw StorageError.keychain(status) }
    }

    /// Returns nil only when the item genuinely doesn't exist; throws on other failures.
    static func get(_ account: String) throws -> Data? {
        var result: AnyObject?
        let status = withFallback { dp in
            var query = baseQuery(account, dataProtection: dp)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            return SecItemCopyMatching(query as CFDictionary, &result)
        }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StorageError.keychain(status) }
        return result as? Data
    }

    static func delete(_ account: String) {
        _ = withFallback { dp in SecItemDelete(baseQuery(account, dataProtection: dp) as CFDictionary) }
    }

    /// The database encryption key. Created once; never regenerated if a read merely fails.
    static func storeKey() throws -> SymmetricKey {
        if let existing = try get("store-key") {
            return SymmetricKey(data: existing)
        }
        let key = SymmetricKey(size: .bits256)
        try set(key.withUnsafeBytes { Data($0) }, account: "store-key")
        return key
    }
}

/// The local-first database: one AES-GCM sealed JSON file in Application Support.
struct EncryptedStore: Sendable {
    let url: URL

    init(filename: String = "momentum.store") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Momentum", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent(filename)
    }

    enum LoadResult {
        case fresh
        case loaded(MomentumData)
        /// The file existed but couldn't be opened; it was moved aside, never deleted.
        case recovered(movedTo: URL)
    }

    func load() throws -> LoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .fresh }
        let key = try Keychain.storeKey() // Keychain failures throw: retry later, don't discard data.
        do {
            let sealed = try Data(contentsOf: url)
            let plain = try AES.GCM.open(try AES.GCM.SealedBox(combined: sealed), using: key)
            return .loaded(try JSONCoding.storeDecoder.decode(MomentumData.self, from: plain))
        } catch {
            let aside = url.deletingLastPathComponent()
                .appendingPathComponent("momentum-unreadable-\(Int(Date().timeIntervalSince1970)).store")
            try? FileManager.default.moveItem(at: url, to: aside)
            return .recovered(movedTo: aside)
        }
    }

    func save(_ data: MomentumData) throws {
        let plain = try JSONCoding.encoder.encode(data)
        guard let combined = try AES.GCM.seal(plain, using: try Keychain.storeKey()).combined else { throw StorageError.sealing }
        #if os(iOS)
        try combined.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try combined.write(to: url, options: [.atomic])
        #endif
    }

    func wipe() {
        try? FileManager.default.removeItem(at: url)
        Keychain.delete("store-key")
    }
}

/// Integration credentials live only in the Keychain — never in the database or exports.
struct Secrets {
    enum Key: String, CaseIterable {
        case github, appStoreConnect, revenueCatKey, revenueCatProject, stripe, claude
    }

    func string(_ key: Key) -> String? {
        guard let data = try? Keychain.get("secret.\(key.rawValue)") else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String?, for key: Key) throws {
        if let value, !value.isEmpty {
            try Keychain.set(Data(value.utf8), account: "secret.\(key.rawValue)")
        } else {
            Keychain.delete("secret.\(key.rawValue)")
        }
    }

    var appStoreConnect: AppStoreConnectCredentials? {
        guard let json = string(.appStoreConnect) else { return nil }
        return try? JSONDecoder().decode(AppStoreConnectCredentials.self, from: Data(json.utf8))
    }

    func setAppStoreConnect(_ credentials: AppStoreConnectCredentials?) throws {
        let json = try credentials.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try set(json, for: .appStoreConnect)
    }

    func wipeAll() {
        for key in Key.allCases { Keychain.delete("secret.\(key.rawValue)") }
    }
}
