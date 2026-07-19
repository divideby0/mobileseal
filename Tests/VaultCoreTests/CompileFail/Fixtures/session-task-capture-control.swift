import VaultCore

// CONTROL: Sendable ChunkReader is what crosses task boundaries.
func control(session: consuming UnlockSession) {
    let reader = session.makeReader()
    Task {
        _ = try? reader.metadata(for: FileID())
    }
    session.lock()
}
