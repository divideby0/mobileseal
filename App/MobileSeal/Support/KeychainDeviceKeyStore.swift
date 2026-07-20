import Foundation
import Security
import VaultCore

/// Keychain-backed device-key custody (GOAL WS A.1, review B11 —
/// honest version): the libsodium-generated Ed25519 secret key is
/// stored as a generic-password item with
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — device-bound
/// Keychain custody, NOT Secure-Enclave-resident (the SE cannot host
/// libsodium Ed25519). `ThisDeviceOnly` keeps the key out of every
/// backup and off iCloud Keychain: a restored vault on a new device
/// finds no key and enrolls as a NEW device via TOFU (WS A.3).
///
/// ── THE AUDITED RAW-KEY TRANSFER POINT ──────────────────────────────
/// The Keychain API traffics in `Data`, so raw key bytes MUST exist in
/// ordinary memory exactly here, in two bounded moments:
///   • load: the Keychain `Data` is copied into `SecureBytes` and the
///     intermediary is zeroed before this function returns;
///   • create: the fresh `SecureBytes` key is copied into a `Data`
///     for `SecItemAdd` and that intermediary is zeroed likewise.
/// Nothing else in the app or in VaultCore ever touches raw device-key
/// bytes — `DeviceIdentity` has no secret accessor (compile-fail
/// fixture `devicekey-raw-escape` pins this), and the residual (the
/// unavoidable transient copies inside the Security framework itself)
/// is documented in docs/formats.md §Security notes.
/// ────────────────────────────────────────────────────────────────────
///
/// Simulator/device residual (green gate 4, review A6): tests assert
/// the item's attributes and API behavior; the device-bound/
/// protection-class ENFORCEMENT is hardware behavior, listed on the
/// map's HITL validation checklist, not counted green here.
struct KeychainDeviceKeyStore: DeviceKeyStore {
    static let service = "com.gmail.cedric.hurst.mobileseal.device-key"
    static let account = "device-ed25519-v1"

    /// Test seam: app-hosted unit tests use a scratch account so they
    /// never disturb (or depend on) the real device identity.
    var account: String = KeychainDeviceKeyStore.account

    enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
        case malformedItem
    }

    func loadOrCreateIdentity() throws -> DeviceIdentity {
        if let existing = try loadExisting() {
            return existing
        }
        return try createAndPersist()
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }

    private func loadExisting() throws -> DeviceIdentity? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, data.count == DeviceIdentity.secretKeyBytes
            else { throw KeychainError.malformedItem }
            // AUDITED EXTRACTION: Keychain Data → SecureBytes, then
            // zero the intermediary array storage.
            var bytes = [UInt8](data)
            let secret = try SecureBytes(consumingAndZeroing: &bytes)
            return try DeviceIdentity(consuming: secret)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func createAndPersist() throws -> DeviceIdentity {
        let secret = try DeviceIdentity.generateSecretKey()
        // AUDITED TRANSFER (create direction): SecureBytes → Data for
        // SecItemAdd, intermediary zeroed before return.
        var keyData = Data(count: DeviceIdentity.secretKeyBytes)
        keyData.withUnsafeMutableBytes { dst in
            secret.withUnsafeBytes { src in
                dst.baseAddress!.copyMemory(from: src.baseAddress!, byteCount: src.count)
            }
        }
        defer {
            keyData.withUnsafeMutableBytes { raw in
                raw.baseAddress.map { memset_s($0, raw.count, 0, raw.count) }
            }
        }
        var attributes = baseQuery()
        attributes[kSecValueData as String] = keyData
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Lost a creation race (or a previous create crashed after
            // SecItemAdd): the persisted key wins — idempotence.
            secret.zeroAndFree()
            guard let existing = try loadExisting() else {
                throw KeychainError.malformedItem
            }
            return existing
        }
        guard status == errSecSuccess else {
            secret.zeroAndFree()
            throw KeychainError.unexpectedStatus(status)
        }
        return try DeviceIdentity(consuming: secret)
    }

    /// The stored item's accessibility attribute (test surface for the
    /// gate-4 attribute assertion). nil when no item exists.
    func storedAccessibilityAttribute() throws -> String? {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound { return nil }
            throw KeychainError.unexpectedStatus(status)
        }
        let attrs = result as? [String: Any]
        return attrs?[kSecAttrAccessible as String] as? String
    }

    /// Test-only: removes the scratch item.
    func deleteStoredKey() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
}
