import VaultCore

// CONTROL: reader taken before lock; lock is the last use.
func control(session: consuming UnlockSession) {
    _ = session.makeReader()
    session.lock()
}
