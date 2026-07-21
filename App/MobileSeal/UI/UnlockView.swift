import SwiftUI

/// Password unlock (GOAL WS D.1): password-only this leg — Face ID
/// waits for a custody-respecting biometric-token API in VaultCore.
/// Surfaces VaultCore's rate-limit backoff and the deliberately
/// ambiguous wrong-password/tamper error.
struct UnlockView: View {
    let store: VaultStore

    @State private var password = ""
    @FocusState private var focused: Bool

    private var isWorking: Bool {
        store.phase == .unlocking
    }

    var body: some View {
        VStack(spacing: 24) {
            // Back to the gallery list (CED-14 WS A.2, plan review
            // Q15): a wrong target password leaves the app HERE with
            // everything locked; Back returns to the list.
            if store.canSwitchGalleries {
                HStack {
                    Button {
                        store.backToList()
                    } label: {
                        Label("Galleries", systemImage: "chevron.left")
                    }
                    .accessibilityIdentifier("back-to-list-button")
                    Spacer()
                }
                .padding(.horizontal)
            }
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text(store.selectedGalleryName ?? "MobileSeal")
                .font(.largeTitle.bold())

            SecureField("Password", text: $password)
                .textContentType(.password)
                .submitLabel(.go)
                .focused($focused)
                .onSubmit(attempt)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .accessibilityIdentifier("unlock-password")

            if let failure = store.lastUnlockFailure {
                UnlockFailureText(failure: failure)
            }

            Button(action: attempt) {
                if isWorking {
                    ProgressView()
                } else {
                    Text("Unlock").frame(maxWidth: 240)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(password.isEmpty || isWorking)
            .accessibilityIdentifier("unlock-button")
            Spacer()
            Spacer()
        }
        .padding()
        .onAppear { focused = true }
        // Rollback acceptance flow (CED-13 WS B.7): the detector saw a
        // KNOWN device presenting an older manifest — the signature of
        // an older-backup restore. Continuing re-baselines and RECORDS
        // the acceptance; cancelling leaves the vault locked.
        .alert(
            "Restored from an older backup?",
            isPresented: Binding(
                get: { store.lastUnlockFailure == .restoredFromOlderBackup },
                set: { if !$0 { store.lastUnlockFailure = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Open Anyway") {
                store.unlock(password: password, acceptRollback: true)
                password = ""
            }
            .accessibilityIdentifier("rollback-accept")
        } message: {
            Text(
                "This vault is older than the last one this device saw — usually because it was restored from a backup. If that's expected, continue; the restore will be recorded. If not, someone may have replaced the vault with an older copy."
            )
        }
    }

    private func attempt() {
        guard !password.isEmpty else { return }
        // The password stays in the field until the phase leaves the
        // unlock screen: the rollback acceptance re-submit needs it.
        store.unlock(password: password)
    }
}

struct UnlockFailureText: View {
    let failure: UnlockFailure

    var body: some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.red)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 320)
            .accessibilityIdentifier("unlock-failure")
    }

    private var message: String {
        switch failure {
        case .wrongPasswordOrDamagedKeyring:
            // The two causes are cryptographically indistinguishable
            // (GOAL WS D.5) — the copy says so instead of guessing.
            return
                "The password is wrong, or the vault's key data is damaged — the two are indistinguishable by design. Check the password first."
        case .rateLimited(let seconds):
            return String(
                format: "Too many failed attempts. Try again in %.0f seconds.",
                seconds.rounded(.up))
        case .vaultOpenElsewhere:
            return "The vault is open elsewhere. Close the other view first."
        case .restoredFromOlderBackup:
            // Presented as an alert with the acceptance action; this
            // inline text is the fallback while the alert is up.
            return "This vault looks restored from an older backup."
        case .other(let text):
            return "Unlock failed: \(text)"
        }
    }
}

/// First-run gallery creation (GOAL WS A/D.4): password + confirm;
/// Argon2id calibration runs at creation, before the vault exists.
struct SetupView: View {
    let store: VaultStore

    @State private var password = ""
    @State private var confirmation = ""

    private var isWorking: Bool { store.phase == .creating }
    private var mismatch: Bool {
        !confirmation.isEmpty && password != confirmation
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Create your vault")
                .font(.title.bold())
            Text(
                "Photos you import are encrypted on this device with a key derived from this password. There is no recovery: lose the password and the photos are gone."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 340)

            SecureField("Password", text: $password)
                .textContentType(.newPassword)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .accessibilityIdentifier("setup-password")
            SecureField("Confirm password", text: $confirmation)
                .textContentType(.newPassword)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .accessibilityIdentifier("setup-confirm")

            if mismatch {
                Text("Passwords don't match.")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            if let failure = store.lastUnlockFailure {
                UnlockFailureText(failure: failure)
            }

            Button {
                store.createGallery(password: password)
            } label: {
                if isWorking {
                    HStack {
                        ProgressView()
                        Text("Calibrating device…")
                    }
                } else {
                    Text("Create Vault").frame(maxWidth: 240)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(password.isEmpty || password != confirmation || isWorking)
            .accessibilityIdentifier("setup-create")
            Spacer()
            Spacer()
        }
        .padding()
    }
}
