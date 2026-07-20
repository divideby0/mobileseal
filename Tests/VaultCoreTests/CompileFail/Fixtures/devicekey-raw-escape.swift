import VaultCore

// MISUSE: the device signing key's raw bytes have NO accessor outside
// VaultCore — the single audited extraction point is the app-layer
// Keychain store's copy INTO SecureBytes, and nothing ever copies out
// (GOAL WS A.1 / green gate 4).
func misuse(identity: DeviceIdentity) -> Int {
    let leaked = identity.secretKey
    return leaked.count
}
