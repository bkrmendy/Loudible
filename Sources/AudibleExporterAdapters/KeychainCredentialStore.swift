import Foundation
import Security
import AudibleExporterCore

/// The subset of Keychain Services used for credentials. Unit tests substitute an in-memory fake.
public protocol KeychainServices: Sendable {
    func add(_ attributes: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?)
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

public struct SystemKeychain: KeychainServices {
    public init() {}

    public func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }

    public func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    public func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// Stores the session as JSON in one dedicated generic-password Keychain item.
public struct KeychainCredentialStore: CredentialStore {
    public static let defaultService = "AudibleExporter.AudibleSession"

    public struct KeychainError: Error, Equatable, CustomStringConvertible {
        public let operation: String
        public let status: OSStatus

        public var description: String {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain \(operation) failed: \(message)"
        }
    }

    public struct CorruptItem: Error, CustomStringConvertible {
        public let underlying: String
        public var description: String { "Saved credentials are unreadable: \(underlying)" }
    }

    private let keychain: any KeychainServices
    private let service: String
    private let account: String

    public init(keychain: any KeychainServices = SystemKeychain(), service: String = defaultService, account: String = "default") {
        self.keychain = keychain
        self.service = service
        self.account = account
    }

    private var itemQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() throws -> AudibleSession? {
        var query = itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = keychain.copyMatching(query)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw CorruptItem(underlying: "item has no data") }
            do {
                return try Self.decoder.decode(AudibleSession.self, from: data)
            } catch {
                throw CorruptItem(underlying: String(describing: error))
            }
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(operation: "read", status: status)
        }
    }

    public func save(_ session: AudibleSession) throws {
        let data = try Self.encoder.encode(session)
        let status = keychain.update(itemQuery, attributes: [kSecValueData as String: data])
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = itemQuery
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            attributes[kSecAttrLabel as String] = "AudibleExporter Audible sign-in"
            let addStatus = keychain.add(attributes)
            guard addStatus == errSecSuccess else { throw KeychainError(operation: "add", status: addStatus) }
        default:
            throw KeychainError(operation: "update", status: status)
        }
    }

    public func delete() throws {
        let status = keychain.delete(itemQuery)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(operation: "delete", status: status)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static let decoder = JSONDecoder()
}
