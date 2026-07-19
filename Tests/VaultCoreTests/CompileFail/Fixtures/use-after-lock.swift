import VaultCore

// MISUSE: using the session after consuming lock() must not compile.
func misuse(session: consuming UnlockSession) {
    session.lock()
    _ = session.makeReader()
}
