import VaultCore

// MISUSE: SecureBytes cannot be duplicated (move-only key custody).
func misuse(bytes: consuming SecureBytes) -> Int {
    let a = bytes
    let b = bytes
    return a.count + b.count
}
