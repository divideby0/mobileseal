import SwiftUI
import UIKit

/// SwiftUI-lifecycle app (GOAL WS A.2). Single-scene policy is
/// structural: Info.plist sets `UIApplicationSupportsMultipleScenes`
/// to false, so iOS never creates a second scene; the
/// `galleryAlreadyOpen` mapping ("vault is open elsewhere") remains as
/// defense in depth.
@main
struct MobileSealApp: App {
    @State private var store: VaultStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // A container failure here means Application Support itself is
        // unavailable — nothing sensible to do but crash loudly.
        let container: AppContainer
        if let name = UITestSupport.containerOverride {
            // Scripted-e2e seam: a per-test container so each UI test
            // starts from a clean vault while relaunches share state.
            let base = try! FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("UITest-\(name)", isDirectory: true)
            if UITestSupport.wantsReset {
                try? FileManager.default.removeItem(at: base)
                // Also reset persisted preferences: an earlier run on
                // this simulator (incl. app-hosted unit tests before
                // the defaults-injection seam existed) may have left
                // non-default lock policy behind.
                UserDefaults.standard.removeObject(
                    forKey: LockPreferences.backgroundPolicyKey)
                UserDefaults.standard.removeObject(forKey: LockPreferences.idleTimeoutKey)
            }
            container = try! AppContainer(base: base)
            // CED-13 gate 2: the migration e2e leg starts from the
            // committed pre-migration (v0) vault fixture.
            UITestSupport.seedV0VaultIfRequested(into: container)
        } else {
            container = try! AppContainer.standard()
        }
        // Trust-list registration label (CED-13 WS A.2). Since iOS 16
        // this is the generic model name ("iPhone"), which is fine —
        // the trust list needs a human-recognizable label, not a
        // unique one (identity is the public key).
        let coordinator = VaultCoordinator(
            container: container, deviceName: UIDevice.current.name)
        _store = State(
            initialValue: VaultStore(coordinator: coordinator, container: container))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .task {
                    await store.bootstrap()
                    store.startIdleWatch()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .inactive:
                        // Shield BEFORE the system snapshot; transient
                        // inactivity never locks (Codex A2).
                        store.sceneBecameInactive()
                    case .background:
                        store.sceneEnteredBackground()
                    case .active:
                        store.sceneBecameActive()
                    @unknown default:
                        break
                    }
                }
        }
    }
}

struct ContentView: View {
    let store: VaultStore

    var body: some View {
        ZStack {
            switch store.phase {
            case .starting:
                ProgressView()
            case .needsSetup, .creating:
                SetupView(store: store)
            case .locked, .unlocking:
                UnlockView(store: store)
            case .unlocked:
                // No blanket SwiftUI TapGesture here: a simultaneous
                // gesture over the UIViewRepresentable grid swallows
                // UICollectionView cell selection (didSelectItemAt
                // never fires — found by CED-12's pager gate; latent
                // since CED-11, whose tests never tapped a cell).
                // Interaction noting rides the grid's scroll/select
                // callbacks instead.
                GalleryView(store: store)
            case .locking:
                ProgressView("Locking…")
            case .galleryError(let failure):
                GalleryErrorView(failure: failure)
            }

            if store.shielded {
                // No insertion animation: the shield must be opaque in
                // the same frame the scene resigns active, or the
                // system snapshot can catch mid-fade content
                // (wave-001 codex #2).
                ShieldView()
                    .transaction { $0.animation = nil }
            }
        }
    }
}
