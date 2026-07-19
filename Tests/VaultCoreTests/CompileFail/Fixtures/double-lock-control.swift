import VaultCore

// CONTROL: exactly one consuming lock.
func control(session: consuming UnlockSession) {
    session.lock()
}
