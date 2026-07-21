import CryptoKit
import Foundation
import OSLog
import Security

/// One gallery's device-local label (CED-14 WS B.2, grill Q1): an
/// optional display name and an optional pre-sealed cover JPEG. THIS
/// DEVICE ONLY — labels are never synced, never written into any
/// gallery-format file (custody-canary-gated), like contact nicknames.
struct GalleryLabel: Codable, Equatable, Sendable {
    var name: String?
    /// Downscaled cover image bytes (JPEG), produced in memory from a
    /// decrypted gallery original — no plaintext file ever exists (the
    /// cover pipeline is decrypt → downscale → seal in one pass).
    var coverJPEG: Data?

    var isEmpty: Bool { name == nil && coverJPEG == nil }
}

/// Typed read outcome (plan review B9): every failure degrades to a
/// GENERIC TILE, never a crash — corrupt records, swapped records
/// (AAD mismatch), and a missing post-restore key are all expected
/// states with a defined presentation.
enum GalleryLabelOutcome: Equatable, Sendable {
    case labeled(GalleryLabel)
    /// No record for this gallery — the ordinary unlabeled state.
    case unlabeled
    /// The label AEAD key is not in this device's Keychain (the
    /// DEFINED restore outcome: ciphertext rode backup, the
    /// `ThisDeviceOnly` key did not — labels reset; recovery = relabel).
    case keyUnavailable
    /// Record present but fails AEAD open: corrupt bytes, a record
    /// swapped between galleries (the gallery-UUID AAD binding makes
    /// that a failure, not a cross-applied label), or a key that no
    /// longer matches.
    case unreadable
}

/// Custody seam for the label AEAD key so app-hosted tests never
/// touch the real Keychain item.
protocol LabelKeyStore: Sendable {
    /// The key, or nil when absent (reads must NOT mint a key — a
    /// fresh key cannot decrypt existing records, and minting on read
    /// would turn the typed `keyUnavailable` state into `unreadable`).
    func loadKey() throws -> SymmetricKey?
    /// The key, created and persisted first if absent (write path).
    func loadOrCreateKey() throws -> SymmetricKey
}

/// Keychain-backed label-key custody (CED-14 WS B.2, plan review B8):
/// a NEW dedicated generic-password item — DISTINCT from the
/// device-identity key — holding 32 random bytes under
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. `ThisDeviceOnly`
/// keeps it out of every backup: restored label ciphertext without
/// this key is the defined graceful-loss path.
struct KeychainLabelKeyStore: LabelKeyStore {
    static let service = "com.gmail.cedric.hurst.mobileseal.label-store-key"
    static let account = "label-aead-v1"

    /// Test seam: scratch account, same as KeychainDeviceKeyStore's.
    var account: String = KeychainLabelKeyStore.account

    enum KeychainError: Error {
        case unexpectedStatus(OSStatus)
        case malformedItem
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
    }

    func loadKey() throws -> SymmetricKey? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, data.count == 32 else {
                throw KeychainError.malformedItem
            }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func loadOrCreateKey() throws -> SymmetricKey {
        if let existing = try loadKey() { return existing }
        let key = SymmetricKey(size: .bits256)
        var attributes = baseQuery()
        attributes[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Lost a creation race: the persisted key wins.
            guard let existing = try loadKey() else { throw KeychainError.malformedItem }
            return existing
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        return key
    }

    /// Test-only: removes the scratch item.
    func deleteStoredKey() {
        SecItemDelete(baseQuery() as CFDictionary)
    }
}

/// Sealed label records on disk (CED-14 WS B.2): one
/// `Labels/label-<gallery-uuid>.sealed` per gallery under Application
/// Support, AEAD-sealed (ChaChaPoly) under the Keychain label key with
/// the gallery UUID as AAD. The ciphertext MAY ride device backup;
/// the key never does.
struct GalleryLabelStore: Sendable {
    private static let log = Logger(
        subsystem: "com.gmail.cedric.hurst.mobileseal", category: "labels")

    let container: AppContainer
    var keyStore: any LabelKeyStore = KeychainLabelKeyStore()

    private func aad(for galleryID: UUID) -> Data {
        Data(galleryID.uuidString.lowercased().utf8)
    }

    /// Reads one gallery's label. NEVER throws to the UI: every
    /// failure is a typed outcome that renders as a generic tile.
    func label(for galleryID: UUID) -> GalleryLabelOutcome {
        let url = container.labelURL(galleryID: galleryID)
        guard let sealed = try? Data(contentsOf: url) else { return .unlabeled }
        let key: SymmetricKey
        do {
            guard let loaded = try keyStore.loadKey() else { return .keyUnavailable }
            key = loaded
        } catch {
            Self.log.error(
                "label key load failed: \(String(describing: error), privacy: .public)")
            return .keyUnavailable
        }
        do {
            let box = try ChaChaPoly.SealedBox(combined: sealed)
            let plaintext = try ChaChaPoly.open(box, using: key, authenticating: aad(for: galleryID))
            let label = try JSONDecoder().decode(GalleryLabel.self, from: plaintext)
            return .labeled(label)
        } catch {
            // Corrupt, swapped (AAD mismatch), or key-mismatched
            // record: typed degradation, no crash (plan review B9).
            Self.log.error("label record unreadable for \(galleryID, privacy: .public)")
            return .unreadable
        }
    }

    /// Writes one gallery's label (creating the AEAD key on first
    /// write). An empty label removes the record instead — no
    /// zero-content ciphertext files accumulate.
    func setLabel(_ label: GalleryLabel, for galleryID: UUID) throws {
        let url = container.labelURL(galleryID: galleryID)
        if label.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let key = try keyStore.loadOrCreateKey()
        let plaintext = try JSONEncoder().encode(label)
        let box = try ChaChaPoly.seal(plaintext, using: key, authenticating: aad(for: galleryID))
        try box.combined.write(to: url, options: [.atomic])
    }

    /// Convenience: current label (or empty) for read-modify-write.
    func currentLabel(for galleryID: UUID) -> GalleryLabel {
        if case .labeled(let label) = label(for: galleryID) { return label }
        return GalleryLabel()
    }

    /// The cover pipeline's in-memory transform (plan review B9): a
    /// decrypted original's bytes → downscaled JPEG, entirely in
    /// memory — the caller seals the result immediately; no plaintext
    /// file ever exists. Decoded pixels transiting the heap here are
    /// the DISCLOSED memory residual.
    static func makeCoverJPEG(fromDecryptedOriginal data: Data) throws -> Data {
        let output = try Thumbnailer.makeThumbnail(from: data)
        return Data(output.bytes)
    }
}
