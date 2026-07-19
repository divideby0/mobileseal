import SwiftUI

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
            }
            container = try! AppContainer(base: base)
        } else {
            container = try! AppContainer.standard()
        }
        let coordinator = VaultCoordinator(container: container)
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
                GalleryView(store: store)
                    .simultaneousGesture(
                        TapGesture().onEnded { store.noteInteraction() }
                    )
            case .locking:
                ProgressView("Locking…")
            case .galleryError(let failure):
                GalleryErrorView(failure: failure)
            }

            if store.shielded {
                ShieldView()
            }
        }
        .animation(.default, value: store.shielded)
    }
}
