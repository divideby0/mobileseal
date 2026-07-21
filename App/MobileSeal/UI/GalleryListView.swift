import SwiftUI

/// The gallery switcher list (CED-14 WS B.1) — the app root whenever
/// more than one gallery (or any discovery failure) exists. Holds NO
/// DEK: every tile is sealed-plane + device-local material only —
/// lock state, registry created-date, and the OPTIONAL device-local
/// label (name/cover; an explicit per-device opt-in leak, grill Q1).
/// No media counts, nothing derived from gallery plaintext (plan
/// review A11). The whole surface sits behind the global `.inactive`
/// shield, and decoded covers purge when it rises (plan review Q19).
struct GalleryListView: View {
    let store: VaultStore

    @State private var showCreate = false

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16)]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(
                        Array(store.registrySnapshot.records.enumerated()), id: \.element.id
                    ) { index, record in
                        Button {
                            store.selectGallery(record.id)
                        } label: {
                            GalleryTile(
                                record: record, index: index, store: store)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("gallery-tile-\(index)")
                    }
                    ForEach(store.registrySnapshot.failures) { failure in
                        GalleryErrorTile(failure: failure)
                            .accessibilityIdentifier("gallery-error-tile-\(failure.id)")
                    }
                }
                .padding()
            }
            .navigationTitle("Galleries")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showCreate = true
                    } label: {
                        Label("New Gallery", systemImage: "plus")
                    }
                    .accessibilityIdentifier("new-gallery-button")
                }
            }
            .sheet(isPresented: $showCreate) {
                CreateGalleryView(store: store)
            }
            .task {
                await store.switchboard.refreshRegistry()
            }
        }
    }
}

/// One gallery's tile: cover (if this device labeled one) or a
/// generic sealed glyph; name (device-local) or a positional
/// fallback; registry created-date; lock state.
private struct GalleryTile: View {
    let record: GalleryRecord
    let index: Int
    let store: VaultStore

    private var name: String {
        if case .labeled(let label) = store.galleryLabels[record.id] ?? .unlabeled,
            let name = label.name, !name.isEmpty
        {
            return name
        }
        return "Gallery \(index + 1)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemBackground))
                #if os(iOS)
                    if let cover = store.coverImages[record.id] {
                        Image(uiImage: cover)
                            .resizable()
                            .scaledToFill()
                            .frame(minWidth: 0)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        genericGlyph
                    }
                #else
                    genericGlyph
                #endif
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .padding(6)
                            .background(.thinMaterial, in: Circle())
                            .padding(6)
                    }
                    Spacer()
                }
            }
            .aspectRatio(1, contentMode: .fit)

            Text(name)
                .font(.headline)
                .lineLimit(1)
            if let created = record.createdAt {
                Text(created, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
    }

    private var genericGlyph: some View {
        Image(systemName: "lock.shield")
            .font(.system(size: 40))
            .foregroundStyle(.secondary)
    }
}

/// A directory the registry cannot honestly list (CED-14 WS B.1, plan
/// review B7): duplicate gallery UUIDs (a copied directory) or an
/// unreadable `gallery.meta` — an ERROR TILE, never silent data loss
/// and never an openable entry whose UUID-keyed device state would
/// cross-apply.
private struct GalleryErrorTile: View {
    let failure: GalleryDiscoveryFailure

    private var message: String {
        switch failure.reason {
        case .duplicateGalleryID:
            return "Duplicate gallery — this folder is a copy of another gallery. Remove or separate the copies to open them."
        case .unreadableMeta:
            return "Unreadable gallery — its key data is missing or damaged."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.yellow.opacity(0.15))
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.yellow)
            }
            .aspectRatio(1, contentMode: .fit)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}

/// New-gallery creation (CED-14 WS A.1): optional device-local name,
/// password + confirm; per-gallery Argon2id calibration runs at
/// creation (the CED-11 calibrator, per gallery). Presented as a
/// sheet from the list and from Settings (the one-gallery affordance,
/// plan review Q16); success re-routes the app into the new gallery,
/// dismissing the presenter.
struct CreateGalleryView: View {
    let store: VaultStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var password = ""
    @State private var confirmation = ""

    private var isWorking: Bool { store.phase == .creating }
    private var mismatch: Bool {
        !confirmation.isEmpty && password != confirmation
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (optional, this device only)", text: $name)
                        .accessibilityIdentifier("create-name")
                } footer: {
                    Text(
                        "The name is stored only on this device, encrypted — it is never written into the gallery or synced."
                    )
                }
                Section {
                    SecureField("Password", text: $password)
                        .textContentType(.newPassword)
                        .accessibilityIdentifier("create-password")
                    SecureField("Confirm password", text: $confirmation)
                        .textContentType(.newPassword)
                        .accessibilityIdentifier("create-confirm")
                } footer: {
                    Text(
                        "Each gallery has its own password and key. There is no recovery: lose the password and the photos are gone."
                    )
                }
                if mismatch {
                    Text("Passwords don't match.")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                if let failure = store.lastUnlockFailure {
                    UnlockFailureText(failure: failure)
                }
                Section {
                    Button {
                        store.createGallery(password: password, name: name)
                    } label: {
                        if isWorking {
                            HStack {
                                ProgressView()
                                Text("Calibrating device…")
                            }
                        } else {
                            Text("Create Gallery")
                        }
                    }
                    .disabled(password.isEmpty || password != confirmation || isWorking)
                    .accessibilityIdentifier("create-submit")
                }
            }
            .navigationTitle("New Gallery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(isWorking)
                }
            }
        }
        .interactiveDismissDisabled(isWorking)
    }
}
