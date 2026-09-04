import Foundation
import Security

/// The token is a bearer capability, so it is kept in the extension's normal
/// Keychain rather than in user defaults. Discovery metadata alone cannot send
/// files to a paired Android receiver.
public struct StoredCompanion: Codable, Identifiable, Equatable {
    public let id: String
    public var displayName: String
    public let fingerprint: String
    public var lastUsed: Date

    public init(id: String = UUID().uuidString, displayName: String, fingerprint: String, lastUsed: Date = Date()) {
        self.id = id
        self.displayName = PeerText.displayName(displayName, fallback: "Android companion")
        self.fingerprint = fingerprint.lowercased()
        self.lastUsed = lastUsed
    }
}

public enum CompanionCredentialStore {
    private static let recordsKey = "dev.easyshare.companion.records.v1"
    private static let keychainService = "dev.easyshare.companion.pairing-token.v1"

    public static func records() -> [StoredCompanion] {
        guard let data = UserDefaults.standard.data(forKey: recordsKey),
              let records = try? JSONDecoder().decode([StoredCompanion].self, from: data)
        else { return [] }
        return records.filter { validFingerprint($0.fingerprint) }.sorted { $0.lastUsed > $1.lastUsed }
    }

    public static func token(for record: StoredCompanion) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: record.id,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let token = result as? Data, token.count == 32
        else { return nil }
        return token
    }

    public static func save(_ record: StoredCompanion, token: Data) throws {
        guard token.count == 32, validFingerprint(record.fingerprint) else { throw CompanionError.invalidResponse("invalid pairing credentials") }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: record.id,
        ]
        let add = query.merging([kSecValueData: token]) { _, new in new }
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(query as CFDictionary, [kSecValueData: token] as CFDictionary)
            guard update == errSecSuccess else { throw CompanionError.keychain(update) }
        } else if status != errSecSuccess {
            throw CompanionError.keychain(status)
        }
        var values = records().filter { $0.id != record.id && $0.fingerprint != record.fingerprint }
        values.append(record)
        values.sort { $0.lastUsed > $1.lastUsed }
        let retained = Array(values.prefix(8))
        // Remove credentials only for a record we deliberately evicted.
        for removed in values.dropFirst(8) { deleteToken(for: removed.id) }
        guard let encoded = try? JSONEncoder().encode(retained) else { throw CompanionError.invalidResponse("could not save pairing") }
        UserDefaults.standard.set(encoded, forKey: recordsKey)
    }

    public static func markUsed(_ record: StoredCompanion) {
        var values = records()
        guard let index = values.firstIndex(where: { $0.id == record.id }) else { return }
        values[index].lastUsed = Date()
        guard let data = try? JSONEncoder().encode(values) else { return }
        UserDefaults.standard.set(data, forKey: recordsKey)
    }

    private static func deleteToken(for id: String) {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: id,
        ] as CFDictionary)
    }

    private static func validFingerprint(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }
}
