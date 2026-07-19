import VaultCore

// CONTROL: a single move of a SecureBytes value is fine.
func control(bytes: consuming SecureBytes) -> Int {
    let a = bytes
    return a.count
}
