import Foundation

/// Auto-lock preferences (grill Q2): policy, not custody — stored in
/// UserDefaults. Strict defaults: immediate lock on `.background`,
/// 5-minute foreground idle backstop.
enum BackgroundLockPolicy: String, CaseIterable, Identifiable, Sendable {
    case immediate
    case grace
    case off

    var id: String { rawValue }
    var label: String {
        switch self {
        case .immediate: return "Immediately"
        case .grace: return "After 30 seconds"
        case .off: return "Never"
        }
    }
}

/// PER-GALLERY since CED-14 (WS A.3, plan review B5): the two
/// pre-CED-14 global keys migrate one-time to gallery #1's keys and
/// are removed. Policy handoff across a switch (plan review Q18): the
/// OLD gallery's policy applies until its lock completes; the LIST
/// screen holds no DEK and needs no policy; the target's policy arms
/// when the store loads it at selection.
struct LockPreferences: Equatable, Sendable {
    /// Pre-CED-14 GLOBAL keys — migration source + reset targets only.
    static let legacyBackgroundPolicyKey = "lock.backgroundPolicy"
    static let legacyIdleTimeoutKey = "lock.idleTimeoutSeconds"
    /// Common prefix of every lock-preference key, legacy and
    /// per-gallery — the UI-test reset sweeps this prefix.
    static let keyPrefix = "lock."

    static func backgroundPolicyKey(galleryID: UUID) -> String {
        "lock.backgroundPolicy.\(galleryID.uuidString.lowercased())"
    }

    static func idleTimeoutKey(galleryID: UUID) -> String {
        "lock.idleTimeoutSeconds.\(galleryID.uuidString.lowercased())"
    }

    var backgroundPolicy: BackgroundLockPolicy = .immediate
    /// Foreground idle backstop; 0 disables.
    var idleTimeout: TimeInterval = 300
    /// Grace window before a backgrounded app counts as "away".
    /// Instance-level (not persisted) so gate-5 tests can exercise the
    /// lock-after-window branch with a tiny window (wave-001 cc #11).
    var gracePeriod: TimeInterval = 30

    static func load(from defaults: UserDefaults = .standard, galleryID: UUID) -> LockPreferences {
        var prefs = LockPreferences()
        if let raw = defaults.string(forKey: backgroundPolicyKey(galleryID: galleryID)),
            let policy = BackgroundLockPolicy(rawValue: raw)
        {
            prefs.backgroundPolicy = policy
        }
        if defaults.object(forKey: idleTimeoutKey(galleryID: galleryID)) != nil {
            prefs.idleTimeout = defaults.double(forKey: idleTimeoutKey(galleryID: galleryID))
        }
        return prefs
    }

    func save(to defaults: UserDefaults = .standard, galleryID: UUID) {
        defaults.set(
            backgroundPolicy.rawValue, forKey: Self.backgroundPolicyKey(galleryID: galleryID))
        defaults.set(idleTimeout, forKey: Self.idleTimeoutKey(galleryID: galleryID))
    }

    /// One-time migration of the pre-CED-14 GLOBAL values onto gallery
    /// #1's keys (WS A.3). Idempotent at every crash point: values are
    /// copied only while the target keys are absent, and the legacy
    /// keys are removed only after both copies — a re-run after any
    /// interruption converges without overwriting later edits.
    static func migrateLegacy(to galleryID: UUID, defaults: UserDefaults = .standard) {
        let policyKey = backgroundPolicyKey(galleryID: galleryID)
        let idleKey = idleTimeoutKey(galleryID: galleryID)
        if defaults.object(forKey: policyKey) == nil,
            let raw = defaults.string(forKey: legacyBackgroundPolicyKey)
        {
            defaults.set(raw, forKey: policyKey)
        }
        if defaults.object(forKey: idleKey) == nil,
            defaults.object(forKey: legacyIdleTimeoutKey) != nil
        {
            defaults.set(defaults.double(forKey: legacyIdleTimeoutKey), forKey: idleKey)
        }
        defaults.removeObject(forKey: legacyBackgroundPolicyKey)
        defaults.removeObject(forKey: legacyIdleTimeoutKey)
    }

    /// UI-test reset (CED-14 WS A.3): clears the legacy globals AND
    /// every per-gallery key — an earlier run's per-gallery policy
    /// must not poison a later launch on the same simulator.
    static func resetAll(in defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
