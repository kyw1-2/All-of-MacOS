import CryptoKit
import Foundation
import Security

/// The history payload is authenticated and encrypted; its key lives in this
/// user's login Keychain, never alongside the archive or in UserDefaults.
enum ClipboardArchiveEncryption {
    private static let service = "com.kyw.allofmacos.clipboard-history"
    private static let account = "history-v2-aes256"
    private static let keyLock = NSRecursiveLock()
    private static var cachedKey: SymmetricKey?

    enum Failure: LocalizedError {
        case keychain(OSStatus), invalidKey, missingKey
        var errorDescription: String? {
            switch self {
            case .keychain: return "Unlock the login Keychain to access clipboard history. Your saved history has been preserved."
            case .invalidKey, .missingKey: return "The clipboard encryption key is unavailable. Your saved history has been preserved."
            }
        }
    }

    static func encrypt(_ data: Data) throws -> Data {
        let key = try loadKey(createIfMissing: true)
        guard let sealed = try AES.GCM.seal(data, using: key).combined else { throw Failure.invalidKey }
        return sealed
    }

    static func decrypt(_ data: Data) throws -> Data {
        let key = try loadKey(createIfMissing: false)
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
    }

    private static func loadKey(createIfMissing: Bool) throws -> SymmetricKey {
        keyLock.lock()
        defer { keyLock.unlock() }
        if let cachedKey { return cachedKey }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            guard let data = result as? Data, data.count == 32 else { throw Failure.invalidKey }
            let key = SymmetricKey(data: data)
            cachedKey = key
            return key
        }
        guard status == errSecItemNotFound else { throw Failure.keychain(status) }
        guard createIfMissing else { throw Failure.missingKey }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        let create: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrLabel: "All of MacOS Clipboard History",
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: data
        ]
        let added = SecItemAdd(create as CFDictionary, nil)
        if added == errSecDuplicateItem { return try loadKey(createIfMissing: false) }
        guard added == errSecSuccess else { throw Failure.keychain(added) }
        cachedKey = key
        return key
    }
}
