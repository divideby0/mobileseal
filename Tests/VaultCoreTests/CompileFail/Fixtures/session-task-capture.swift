import VaultCore

// MISUSE: a session must not be smuggled into a concurrent Task.
func misuse(session: consuming UnlockSession) {
    Task {
        session.lock()
    }
}
