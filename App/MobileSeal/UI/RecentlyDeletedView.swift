import SwiftUI
import VaultCore

/// Recently Deleted (CED-13 WS C.2, iPhone parity): soft-deleted
/// aggregates with previews (their entries are untouched until purge,
/// so posters/thumbnails still render from the vault), a days-left
/// clock, restore, and permanent removal (hard Tombstones for the
/// whole aggregate). Copy says "remove" — space is reclaimed at the
/// GC leg.
struct RecentlyDeletedView: View {
    let store: VaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmPurgeID: FileID?

    var body: some View {
        NavigationStack {
            Group {
                if store.recentlyDeleted.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing here", systemImage: "trash")
                    } description: {
                        Text(
                            "Removed items stay here for \(RecentlyDeletedStore.retentionDays) days before they are removed from the vault."
                        )
                    }
                } else {
                    List(store.recentlyDeleted) { deleted in
                        RecentlyDeletedRow(
                            deleted: deleted, pipeline: store.thumbnails,
                            onRestore: {
                                store.restoreDeleted(deleted.id)
                            },
                            onPurge: {
                                confirmPurgeID = deleted.id
                            })
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Recently Deleted")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("recently-deleted-done")
                }
            }
            .confirmationDialog(
                "Remove permanently?",
                isPresented: Binding(
                    get: { confirmPurgeID != nil },
                    set: { if !$0 { confirmPurgeID = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove Permanently", role: .destructive) {
                    if let id = confirmPurgeID {
                        store.purgeDeleted([id])
                    }
                    confirmPurgeID = nil
                }
                .accessibilityIdentifier("confirm-purge")
            } message: {
                Text("The item is removed from the vault on every future sync. This cannot be undone.")
            }
        }
        .accessibilityIdentifier("recently-deleted")
    }
}

private struct RecentlyDeletedRow: View {
    let deleted: RecentlyDeletedItem
    let pipeline: ThumbnailPipeline
    let onRestore: () -> Void
    let onPurge: () -> Void

    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(.secondarySystemBackground)
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(deleted.item.filename ?? "Item")
                    .lineLimit(1)
                Text(
                    deleted.daysLeft == 0
                        ? "Removes on next unlock"
                        : "\(deleted.daysLeft) day\(deleted.daysLeft == 1 ? "" : "s") left"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restore", action: onRestore)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("restore-\(deleted.id.description)")
            Button(role: .destructive, action: onPurge) {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("purge-\(deleted.id.description)")
        }
        .accessibilityIdentifier("deleted-row-\(deleted.id.description)")
        .task {
            thumbnail = await pipeline.image(for: deleted.item)
        }
    }
}
