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

struct LockPreferences: Equatable, Sendable {
    static let backgroundPolicyKey = "lock.backgroundPolicy"
    static let idleTimeoutKey = "lock.idleTimeoutSeconds"

    var backgroundPolicy: BackgroundLockPolicy = .immediate
    /// Foreground idle backstop; 0 disables.
    var idleTimeout: TimeInterval = 300
    /// Grace window before a backgrounded app counts as "away".
    /// Instance-level (not persisted) so gate-5 tests can exercise the
    /// lock-after-window branch with a tiny window (wave-001 cc #11).
    var gracePeriod: TimeInterval = 30

    static func load(from defaults: UserDefaults = .standard) -> LockPreferences {
        var prefs = LockPreferences()
        if let raw = defaults.string(forKey: backgroundPolicyKey),
            let policy = BackgroundLockPolicy(rawValue: raw)
        {
            prefs.backgroundPolicy = policy
        }
        if defaults.object(forKey: idleTimeoutKey) != nil {
            prefs.idleTimeout = defaults.double(forKey: idleTimeoutKey)
        }
        return prefs
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(backgroundPolicy.rawValue, forKey: Self.backgroundPolicyKey)
        defaults.set(idleTimeout, forKey: Self.idleTimeoutKey)
    }
}
