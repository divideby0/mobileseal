import VaultCore

// CONTROL: the PUBLIC key is freely readable; only the secret key is
// custody-sealed.
func control(identity: DeviceIdentity) -> Int {
    identity.publicKey.bytes.count
}
