import SwiftUI
import VaultCore

/// The unlocked gallery: grid + import + explicit lock control.
struct GalleryView: View {
    let store: VaultStore

    @State private var showPicker = false
    @State private var showSettings = false
    /// Multi-select delete state (CED-13 WS C.2).
    @State private var selectionMode = false
    @State private var selection: Set<FileID> = []
    @State private var confirmBulkDelete = false
    /// Pre-share custody warning (CED-15 WS A.1) — generic by design:
    /// the share sheet cannot reveal the destination.
    @State private var confirmBulkShare = false
    @State private var showRecentlyDeleted = false

    private var inboxPromptTitle: String {
        let count = store.pendingInboxPrompt?.items.count ?? 0
        let gallery = store.selectedGalleryName ?? "this gallery"
        return "Import \(count) staged \(count == 1 ? "item" : "items") into \(gallery)?"
    }

    private var inboxPromptMessage: String {
        var lines = [
            "Another app shared these into MobileSeal. They are staged encrypted and import into the currently unlocked gallery."
        ]
        if let expired = store.pendingInboxPrompt?.expiredCount, expired > 0 {
            lines.append(
                "\(expired) older staged \(expired == 1 ? "item" : "items") expired to stay within storage limits."
            )
        }
        lines.append("Declined items stay staged — review them under Settings.")
        return lines.joined(separator: "\n")
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    ContentUnavailableView {
                        Label("No photos yet", systemImage: "photo.on.rectangle.angled")
                    } description: {
                        Text("Import photos from your library. Originals are kept byte-exact and encrypted.")
                    } actions: {
                        Button("Import Photos") { showPicker = true }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("empty-import-button")
                    }
                } else {
                    PhotoGridView(
                        items: store.items,
                        store: store,
                        pipeline: store.thumbnails,
                        onScroll: { store.noteInteraction() },
                        selectionMode: selectionMode,
                        selection: selection,
                        onToggleSelection: { id in
                            if selection.contains(id) {
                                selection.remove(id)
                            } else {
                                selection.insert(id)
                            }
                        }
                    )
                    .ignoresSafeArea(edges: .bottom)
                }
            }
            .navigationTitle(
                selectionMode
                    ? (selection.isEmpty
                        ? "Select Items" : "\(selection.count) Selected")
                    : (store.selectedGalleryName ?? "MobileSeal")
            )
            .navigationBarTitleDisplayMode(selectionMode ? .inline : .automatic)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if selectionMode {
                        Button("Cancel") {
                            selectionMode = false
                            selection = []
                        }
                        .accessibilityIdentifier("select-cancel-button")
                    } else {
                        Button {
                            store.lock()
                        } label: {
                            Label("Lock", systemImage: "lock.fill")
                        }
                        .accessibilityIdentifier("lock-button")
                    }
                }
                // Bulk share rides the BOTTOM bar (CED-15 WS A.1): a
                // third top-trailing item would make iOS collapse the
                // bar into a system overflow (the CED-13 e2e lesson
                // noted below).
                ToolbarItemGroup(placement: .bottomBar) {
                    if selectionMode {
                        Button {
                            confirmBulkShare = true
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .disabled(selection.isEmpty || store.exportActive)
                        .accessibilityIdentifier("select-share-button")
                        Spacer()
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if selectionMode {
                        // Cover opt-in (CED-14 WS B.2, grill Q1):
                        // exactly one selected item can become this
                        // gallery's device-local cover — an explicit
                        // per-device pre-unlock leak the user chooses.
                        Button {
                            if let id = selection.first {
                                store.setCover(from: id)
                            }
                            selectionMode = false
                            selection = []
                        } label: {
                            Label("Set Cover", systemImage: "photo.badge.checkmark")
                        }
                        .disabled(selection.count != 1)
                        .accessibilityIdentifier("select-set-cover-button")
                        Button(role: .destructive) {
                            confirmBulkDelete = true
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        .disabled(selection.isEmpty)
                        .accessibilityIdentifier("select-delete-button")
                    } else {
                        // Exactly TWO trailing items (More + Import):
                        // a third makes iOS collapse the bar into a
                        // system overflow "More", burying this menu a
                        // level deeper (bit the CED-13 e2e). The
                        // UI-test seams therefore live INSIDE the
                        // menu, matched by label — SwiftUI does not
                        // propagate accessibility identifiers onto
                        // menu items.
                        Menu {
                            Button {
                                selectionMode = true
                                selection = []
                            } label: {
                                Label("Select", systemImage: "checkmark.circle")
                            }
                            .disabled(store.items.isEmpty)
                            Button {
                                showRecentlyDeleted = true
                            } label: {
                                Label(
                                    "Recently Deleted (\(store.recentlyDeleted.count))",
                                    systemImage: "trash")
                            }
                            if store.canSwitchGalleries {
                                // Switch = back to the list, which
                                // LOCKS this gallery first (full
                                // teardown; the list holds no DEK —
                                // CED-14 WS A.2, grill Q2).
                                Button {
                                    store.backToList()
                                } label: {
                                    Label(
                                        "Switch Gallery",
                                        systemImage: "square.grid.2x2")
                                }
                            }
                            Button {
                                showSettings = true
                            } label: {
                                Label("Settings", systemImage: "gearshape")
                            }
                            if UITestSupport.isUITestMode {
                                // Scripted-e2e seam (gate 2): the
                                // committed fixture batch through the
                                // real pipeline, fake picker.
                                Button("Import Fixtures") {
                                    store.startImport(
                                        providers: UITestSupport.fixtureBatchProviders())
                                }
                                // Gate 3's 500-photo fixture gallery.
                                Button("Seed 500") {
                                    Task { await store.coordinator.seedGallery(count: 500) }
                                }
                                // CED-14 gate 2's small per-gallery
                                // import (real commits through the
                                // Gallery actor; batch fidelity is
                                // E2EFlowUITests' job).
                                Button("Seed 12") {
                                    Task { await store.coordinator.seedGallery(count: 12) }
                                }
                            }
                        } label: {
                            Label("More", systemImage: "ellipsis.circle")
                        }
                        .accessibilityIdentifier("more-menu-button")
                        Button {
                            showPicker = true
                        } label: {
                            Label("Import", systemImage: "plus")
                        }
                        .disabled(store.importProgress != nil)
                        .accessibilityIdentifier("import-button")
                    }
                }
            }
            .confirmationDialog(
                selection.count == 1
                    ? "Remove this item?" : "Remove \(selection.count) items?",
                isPresented: $confirmBulkDelete,
                titleVisibility: .visible
            ) {
                Button(
                    selection.count == 1 ? "Remove" : "Remove \(selection.count) Items",
                    role: .destructive
                ) {
                    store.softDelete(Array(selection))
                    selectionMode = false
                    selection = []
                }
                .accessibilityIdentifier("confirm-bulk-remove")
            } message: {
                Text(
                    "Removed items move to Recently Deleted for \(RecentlyDeletedStore.retentionDays) days, then are removed from the vault."
                )
            }
            .confirmationDialog(
                ExportShareFlow.warningTitle(count: selection.count),
                isPresented: $confirmBulkShare,
                titleVisibility: .visible
            ) {
                Button(selection.count == 1 ? "Share" : "Share \(selection.count) Items") {
                    let items = store.items.filter { selection.contains($0.id) }
                    selectionMode = false
                    selection = []
                    ExportShareFlow.stageAndPresent(store: store, items: items, anchor: nil)
                }
                .accessibilityIdentifier("confirm-bulk-share")
            } message: {
                Text(ExportShareFlow.warningMessage)
            }
            .alert(
                "Share failed",
                isPresented: Binding(
                    get: { store.lastExportError != nil },
                    set: { if !$0 { store.lastExportError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(store.lastExportError ?? "")
            }
            // Share-inbox prompt (CED-15 WS B.2, Codex A4): exactly
            // once per staged batch; accept claims the batch into THIS
            // unlocked gallery through the switch authority.
            .alert(
                inboxPromptTitle,
                isPresented: Binding(
                    get: { store.pendingInboxPrompt != nil },
                    set: { if !$0 { store.declineInboxPrompt() } }
                )
            ) {
                Button("Import") { store.acceptInboxImport() }
                    .accessibilityIdentifier("inbox-import-button")
                Button("Not Now", role: .cancel) { store.declineInboxPrompt() }
                    .accessibilityIdentifier("inbox-decline-button")
            } message: {
                Text(inboxPromptMessage)
            }
            .overlay(alignment: .bottom) {
                if let progress = store.importProgress {
                    ImportProgressBar(progress: progress)
                        .padding()
                }
            }
            .safeAreaInset(edge: .top) {
                // Recovery status is REPORTED, not just counted
                // (Codex B2; wave-001 codex #5): orphaned links and
                // undecodable entries surface to the user.
                let attention =
                    store.indexReport.orphanThumbnails
                    + store.indexReport.undecodableEntries
                if attention > 0 {
                    Label(
                        "\(attention) vault \(attention == 1 ? "entry needs" : "entries need") attention — orphaned or unreadable link records",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.yellow.opacity(0.2))
                    .accessibilityIdentifier("recovery-banner")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if UITestSupport.isUITestMode {
                    VStack(alignment: .trailing, spacing: 2) {
                        #if DEBUG
                            // CED-12 gate 2's tampered-item leg:
                            // damage the newest playable video on
                            // disk. Compiled out of Release with its
                            // backing primitives.
                            Button("Tamper Video") {
                                store.debugTamperNewestPlayableVideo()
                            }
                            .font(.caption2)
                            .accessibilityIdentifier("tamper-video-button")
                        #endif
                        // Machine-readable item count: the perf test's
                        // seed-completion signal (visible cell counts
                        // cannot observe off-screen population).
                        Text("\(store.items.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("item-count")
                    }
                    .padding(4)
                }
            }
            .sheet(isPresented: $showPicker) {
                PhotoPicker { providers in
                    showPicker = false
                    guard !providers.isEmpty else { return }
                    store.startImport(providers: providers)
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(store: store)
            }
            .sheet(isPresented: $showRecentlyDeleted) {
                RecentlyDeletedView(store: store)
            }
            .sheet(
                isPresented: Binding(
                    get: { store.lastImportSummary != nil },
                    set: { if !$0 { store.lastImportSummary = nil } }
                )
            ) {
                if let summary = store.lastImportSummary {
                    ImportSummaryView(summary: summary)
                }
            }
        }
    }
}

struct ImportProgressBar: View {
    let progress: ImportProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ProgressView(
                    value: Double(progress.completed + progress.skipped + progress.failed),
                    total: Double(max(progress.total, 1)))
                Text("\(progress.completed + progress.skipped + progress.failed)/\(progress.total)")
                    .font(.caption.monospacedDigit())
            }
            if let name = progress.currentName {
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("import-progress")
    }
}

/// Batch summary (GOAL WS B.6): which items landed, which skipped as
/// duplicates, which failed — and the interrupted-batch resume prompt
/// (grill Q8).
struct ImportSummaryView: View {
    let summary: ImportSummary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if summary.interrupted {
                    Section {
                        Label(
                            "Import was interrupted before finishing — the items below marked \"not attempted\" were never read. Imported items are safely committed; re-open the picker to import the rest.",
                            systemImage: "pause.circle")
                    }
                }
                Section("Summary") {
                    LabeledContent("Imported", value: "\(summary.importedCount)")
                    LabeledContent("Skipped (duplicates)", value: "\(summary.skippedCount)")
                    LabeledContent("Failed", value: "\(summary.failedCount)")
                    // Machine-readable line for the scripted e2e gate.
                    Text(
                        "imported=\(summary.importedCount) skipped=\(summary.skippedCount) failed=\(summary.failedCount) interrupted=\(summary.interrupted)"
                    )
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("summary-line")
                }
                Section("Items") {
                    ForEach(summary.outcomes, id: \.index) { outcome in
                        HStack {
                            statusIcon(outcome.status)
                            VStack(alignment: .leading) {
                                Text(outcome.name ?? "Item \(outcome.index + 1)")
                                    .lineLimit(1)
                                Text(statusText(outcome.status))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Import finished")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("summary-done")
                }
            }
        }
        .accessibilityIdentifier("import-summary")
    }

    @ViewBuilder
    private func statusIcon(_ status: ImportOutcome.Status) -> some View {
        switch status {
        case .imported:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skippedDuplicate:
            Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .notAttempted:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    private func statusText(_ status: ImportOutcome.Status) -> String {
        switch status {
        case .imported:
            return "Imported"
        case .skippedDuplicate:
            return "Already in the vault — skipped"
        case .failed(let failure):
            switch failure {
            case .undecodableMedia:
                return "Stored byte-exact, but not decodable as an image — no preview"
            case .lowDiskSpace(let required, let available):
                return
                    "Low disk space: needs \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)) free, only \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) available"
            case .vaultLocked:
                return "The vault locked during import"
            case .integrityMismatch(let reason):
                return "Rejected before import — staged bytes don't match their manifest: \(reason)"
            case .providerFailed(let reason):
                return "Couldn't read from the photo library: \(reason)"
            case .vaultError(let reason):
                return "Import failed: \(reason)"
            }
        case .notAttempted:
            return "Not attempted"
        }
    }
}
