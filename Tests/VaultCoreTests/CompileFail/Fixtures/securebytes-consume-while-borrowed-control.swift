import VaultCore

// CONTROL: consume strictly after the scoped borrow ends.
func control(bytes: consuming SecureBytes) {
    bytes.withUnsafeBytes { _ in () }
    bytes.zeroAndFree()
}
