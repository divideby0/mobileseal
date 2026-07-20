import SwiftUI
import VaultCore

/// The unlocked gallery: grid + import + explicit lock control.
struct GalleryView: View {
    let store: VaultStore

    @State private var showPicker = false
    @State private var showSettings = false

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
                        onScroll: { store.noteInteraction() }
                    )
                    .ignoresSafeArea(edges: .bottom)
                }
            }
            .navigationTitle("MobileSeal")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        store.lock()
                    } label: {
                        Label("Lock", systemImage: "lock.fill")
                    }
                    .accessibilityIdentifier("lock-button")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if UITestSupport.isUITestMode {
                        // Scripted-e2e seam (gate 2): feeds the
                        // committed fixture batch through the fixture
                        // provider — the real pipeline, fake picker.
                        Button("Import Fixtures") {
                            store.startImport(
                                providers: UITestSupport.fixtureBatchProviders())
                        }
                        .accessibilityIdentifier("import-fixtures-button")
                        // Gate 3's 500-photo fixture gallery, seeded
                        // directly for scroll-perf measurement.
                        Button("Seed 500") {
                            Task { await store.coordinator.seedGallery(count: 500) }
                        }
                        .accessibilityIdentifier("seed-gallery-button")
                    }
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("settings-button")
                    Button {
                        showPicker = true
                    } label: {
                        Label("Import", systemImage: "plus")
                    }
                    .disabled(store.importProgress != nil)
                    .accessibilityIdentifier("import-button")
                }
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
