import SwiftUI

/// Auto-lock preferences (grill Q2) + device calibration record.
struct SettingsView: View {
    @Bindable var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var calibration: KDFCalibrator.Record?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(
                        "Lock when leaving the app",
                        selection: $store.lockPreferences.backgroundPolicy
                    ) {
                        ForEach(BackgroundLockPolicy.allCases) { policy in
                            Text(policy.label).tag(policy)
                        }
                    }
                    .accessibilityIdentifier("pref-background-policy")

                    Picker(
                        "Lock after inactivity",
                        selection: $store.lockPreferences.idleTimeout
                    ) {
                        Text("1 minute").tag(TimeInterval(60))
                        Text("5 minutes").tag(TimeInterval(300))
                        Text("15 minutes").tag(TimeInterval(900))
                        Text("Never").tag(TimeInterval(0))
                    }
                    .accessibilityIdentifier("pref-idle-timeout")
                } header: {
                    Text("Auto-Lock")
                } footer: {
                    Text(
                        "Strict defaults: lock immediately when leaving the app, and after 5 idle minutes. \"Never\" and grace periods trade custody for convenience — decrypted previews stay in memory until the lock fires."
                    )
                }

                Section {
                    LabeledContent("Unlock", value: "Password only")
                } header: {
                    Text("Security")
                } footer: {
                    Text(
                        "Face ID unlock is deferred until the vault core grows a custody-respecting biometric token API."
                    )
                }

                // Device Argon2id calibration record (GOAL WS D.4 /
                // gate 6): the numbers the device benchmark
                // transcribes into RESULT.md.
                if let calibration {
                    Section("Key-Derivation Calibration") {
                        LabeledContent(
                            "Chosen parameters",
                            value:
                                "\(calibration.chosenOpslimit) ops / \(calibration.chosenMemlimitMiB) MiB"
                        )
                        ForEach(
                            calibration.medians.sorted(by: { $0.key < $1.key }), id: \.key
                        ) { key, median in
                            LabeledContent(
                                "Median \(key)",
                                value: String(format: "%.3f s", median))
                        }
                        LabeledContent("Thermal state", value: calibration.thermalState)
                        if let mem = calibration.availableMemoryMiB {
                            LabeledContent("Free memory at run", value: "\(mem) MiB")
                        }
                        LabeledContent(
                            "Build", value: calibration.releaseBuild ? "release" : "debug")
                        if let reason = calibration.fallbackReason {
                            LabeledContent("Fallback", value: reason)
                                .font(.caption)
                        }
                    }
                    .accessibilityIdentifier("calibration-record")
                }
            }
            .task {
                calibration = store.loadCalibrationRecord()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Privacy shield (Codex A2): covers content from the instant the
/// scene leaves `.active` — BEFORE the system snapshot — and during
/// `.locking`/`.locked` under a shielded scene. Redaction ≠ lock.
struct ShieldView: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
        }
        .ignoresSafeArea()
        .accessibilityIdentifier("privacy-shield")
    }
}

/// Gallery-level integrity failure screen (GOAL WS D.5): damage and
/// wrong-password are different screens for different errors — but
/// keyring-level ambiguity is stated where it exists.
struct GalleryErrorView: View {
    let failure: GalleryFailure

    var body: some View {
        ContentUnavailableView {
            Label("Vault unavailable", systemImage: "exclamationmark.shield")
        } description: {
            Text(message)
        }
        .accessibilityIdentifier("gallery-error")
    }

    private var message: String {
        switch failure {
        case .noValidInventory:
            return
                "No readable index survives in this vault — the encrypted photo data may still be intact, but the app cannot list it. This is damage, not a wrong password: restore from a backup of the vault folder."
        case .inventoryTampered:
            return
                "The vault's index failed its integrity check. This signals corruption or tampering; the app will not silently fall back to older data. Restore from a backup."
        case .other(let text):
            return text
        }
    }
}
