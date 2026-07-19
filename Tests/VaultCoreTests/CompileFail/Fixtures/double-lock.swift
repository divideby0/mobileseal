import VaultCore

// MISUSE: locking twice consumes the session twice.
func misuse(session: consuming UnlockSession) {
    session.lock()
    session.lock()
}
