import VaultCore

// MISUSE: consuming the buffer while a scoped borrow is active.
func misuse(bytes: consuming SecureBytes) {
    bytes.withUnsafeBytes { _ in
        bytes.zeroAndFree()
    }
}
