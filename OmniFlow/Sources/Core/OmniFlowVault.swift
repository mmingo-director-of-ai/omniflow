import CryptoKit
import Foundation
import Security

/// Encryption at rest for OmniFlow's own files (dictation history, conversations,
/// assistant memory). AES-256-GCM with one key per Mac, kept in the Keychain and
/// never written to disk next to the data. Sealed files start with "OFE1".
///
/// Files written before encryption are still read (plaintext JSON never starts
/// with the magic), and callers rewrite them sealed: that is the migration.
/// Files another process must read (the Atlas helper's task workspace) are
/// deliberately not routed through here.
enum OmniFlowVault {
    static let magic = Data("OFE1".utf8)

    enum VaultError: LocalizedError {
        case keyUnavailable, damaged, outsideApp
        var errorDescription: String? {
            switch self {
            case .keyUnavailable: "OmniFlow's encryption key isn't available, so encrypted history can't be read."
            case .damaged: "An encrypted OmniFlow file couldn't be decrypted."
            case .outsideApp: "Only OmniFlow itself may write its private data folder."
            }
        }
    }

    /// True inside the OmniFlow apps. Test and helper binaries compile the same
    /// sources; they must never create the Keychain key (its access list would
    /// belong to them) or rewrite the user's real files.
    static let isAppProcess = Bundle.main.bundleIdentifier?.hasPrefix("com.mengohlabs.") == true

    /// Keychain in the app; an in-memory key everywhere else.
    nonisolated(unsafe) static var keyProvider: any OmniFlowVaultKeyProvider =
        isAppProcess ? OmniFlowKeychainKeyProvider() : OmniFlowEphemeralKeyProvider()

    static func isSealed(_ data: Data) -> Bool { data.starts(with: magic) }

    static func seal(_ plaintext: Data, keys: (any OmniFlowVaultKeyProvider)? = nil) throws -> Data {
        let key = try (keys ?? keyProvider).key(createIfMissing: true)
        guard let combined = try AES.GCM.seal(plaintext, using: key).combined else { throw VaultError.damaged }
        return magic + combined
    }

    /// Returns the plaintext and whether the stored bytes were legacy plaintext.
    static func open(_ stored: Data, keys: (any OmniFlowVaultKeyProvider)? = nil) throws -> (plaintext: Data, wasPlaintext: Bool) {
        guard isSealed(stored) else { return (stored, true) }
        // Never create a key to read: a missing key means the data is unrecoverable, not new.
        let key = try (keys ?? keyProvider).key(createIfMissing: false)
        do {
            let box = try AES.GCM.SealedBox(combined: stored.dropFirst(magic.count))
            return (try AES.GCM.open(box, using: key), false)
        } catch { throw VaultError.damaged }
    }

    static func read(_ url: URL) throws -> (plaintext: Data, wasPlaintext: Bool) {
        try open(Data(contentsOf: url))
    }

    /// Atomic, owner-only write of sealed bytes.
    static func write(_ plaintext: Data, to url: URL) throws {
        let real = NotchLeeStorage.root.standardizedFileURL.path
        guard isAppProcess || !url.standardizedFileURL.path.hasPrefix(real) else { throw VaultError.outsideApp }
        try seal(plaintext).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

protocol OmniFlowVaultKeyProvider: Sendable {
    func key(createIfMissing: Bool) throws -> SymmetricKey
}

/// One 256-bit key per Mac, this-device-only and never synced. Cached after the
/// first read so file access doesn't hit the Keychain each time.
final class OmniFlowKeychainKeyProvider: OmniFlowVaultKeyProvider, @unchecked Sendable {
    private let service = "com.mengohlabs.NotchLee.vault"
    private let account = "file-key-v1"
    private let lock = NSLock()
    private var cached: SymmetricKey?

    func key(createIfMissing: Bool) throws -> SymmetricKey {
        try lock.withLock {
            if let cached { return cached }
            if let stored = try load() { cached = stored; return stored }
            guard createIfMissing else { throw OmniFlowVault.VaultError.keyUnavailable }
            let fresh = SymmetricKey(size: .bits256)
            try store(fresh)
            cached = fresh
            return fresh
        }
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func load() throws -> SymmetricKey? {
        var item: CFTypeRef?
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(search as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, data.count == 32 else {
            throw OmniFlowVault.VaultError.keyUnavailable
        }
        return SymmetricKey(data: data)
    }

    private func store(_ key: SymmetricKey) throws {
        var item = query
        item[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        item[kSecAttrLabel as String] = "OmniFlow history encryption key"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw OmniFlowVault.VaultError.keyUnavailable }
    }
}

/// In-memory key for tests and previews.
final class OmniFlowEphemeralKeyProvider: OmniFlowVaultKeyProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SymmetricKey?
    init(key: SymmetricKey? = nil) { stored = key }
    func key(createIfMissing: Bool) throws -> SymmetricKey {
        try lock.withLock {
            if let stored { return stored }
            guard createIfMissing else { throw OmniFlowVault.VaultError.keyUnavailable }
            let fresh = SymmetricKey(size: .bits256); stored = fresh; return fresh
        }
    }
}
