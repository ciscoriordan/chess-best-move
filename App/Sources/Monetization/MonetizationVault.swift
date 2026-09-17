import Foundation
import os
import Security

/// One stored record of the credits service.
struct MonetizationVaultItem: Sendable, Hashable {
    /// The Keychain account name.
    let account: String
    /// Synchronizable items follow the Apple Account to other devices through iCloud Keychain.
    let synchronizable: Bool

    /// Free analyses, paid boards and the downsell cooldown. Not synchronizable, so each
    /// device has its own; it survives deleting and reinstalling the app.
    static let local = MonetizationVaultItem(account: "credits.local.v1", synchronizable: false)
    /// Purchased-credit bookkeeping. Synchronizable, so the balance follows the Apple Account.
    static let purchased = MonetizationVaultItem(account: "credits.purchased.v1", synchronizable: true)
}

/// Storage for the credits service. The live implementation is the Keychain
/// (`MonetizationKeychainVault`); tests use `MonetizationInMemoryVault`.
protocol MonetizationVault: Sendable {
    /// The stored data, or nil when the item does not exist. Throws when the storage cannot be
    /// read (for example before the first unlock after a restart).
    func data(for item: MonetizationVaultItem) throws -> Data?
    func setData(_ data: Data, for item: MonetizationVaultItem) throws
    func removeData(for item: MonetizationVaultItem) throws
}

struct MonetizationVaultError: Error, CustomStringConvertible {
    let operation: String
    let status: OSStatus

    var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        return "Keychain \(operation) failed with status \(status) (\(message))"
    }
}

/// Generic-password Keychain items, readable after the first unlock
/// (`kSecAttrAccessibleAfterFirstUnlock`). Keychain items outlive the app, so a reinstall
/// does not reset the free analyses.
final class MonetizationKeychainVault: MonetizationVault {
    let service: String

    init(service: String = "com.motomatic.chessbestmove.credits") {
        self.service = service
    }

    func data(for item: MonetizationVaultItem) throws -> Data? {
        var query = baseQuery(for: item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw MonetizationVaultError(operation: "read", status: status)
        }
    }

    func setData(_ data: Data, for item: MonetizationVaultItem) throws {
        let query = baseQuery(for: item)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw MonetizationVaultError(operation: "add", status: addStatus)
            }
        default:
            throw MonetizationVaultError(operation: "update", status: updateStatus)
        }
    }

    func removeData(for item: MonetizationVaultItem) throws {
        let status = SecItemDelete(baseQuery(for: item) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MonetizationVaultError(operation: "delete", status: status)
        }
    }

    private func baseQuery(for item: MonetizationVaultItem) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.account,
            kSecAttrSynchronizable as String: item.synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!,
        ]
    }
}

/// A vault that lives in memory, for tests, previews and the DEBUG gallery. Sharing one
/// instance between two credits services simulates deleting and reinstalling the app: the
/// Keychain survives, everything else starts over.
final class MonetizationInMemoryVault: MonetizationVault, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MonetizationVaultItem: Data] = [:]
    /// When set, every read throws, to simulate a Keychain that is not available yet.
    private var failsReads = false
    /// When set, every write throws.
    private var failsWrites = false

    init() {}

    func data(for item: MonetizationVaultItem) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if failsReads { throw MonetizationVaultError(operation: "read", status: errSecInteractionNotAllowed) }
        return storage[item]
    }

    func setData(_ data: Data, for item: MonetizationVaultItem) throws {
        lock.lock()
        defer { lock.unlock() }
        if failsWrites { throw MonetizationVaultError(operation: "update", status: errSecNotAvailable) }
        storage[item] = data
    }

    func removeData(for item: MonetizationVaultItem) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[item] = nil
    }

    func setFailsReads(_ fails: Bool) {
        lock.lock()
        defer { lock.unlock() }
        failsReads = fails
    }

    func setFailsWrites(_ fails: Bool) {
        lock.lock()
        defer { lock.unlock() }
        failsWrites = fails
    }
}

enum MonetizationLog {
    static let credits = Logger(subsystem: "com.motomatic.chessbestmove", category: "credits")
    static let store = Logger(subsystem: "com.motomatic.chessbestmove", category: "store")
}
