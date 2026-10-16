/*
 Hypnos - Add From Open Windows Sheet

 Picker for adding currently-open windows — photos, videos and slideshows — to an
 existing saved window group. Each added entry captures
 that window's current size, same as saving a fresh group does.
 */

import SwiftUI

struct AddFromOpenWindowsSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    let group: SavedWindowGroup
    @State private var selectedEntryIds: Set<UUID> = []

    /// Snapshotted on appear rather than recomputed per pass: each entry carries
    /// a freshly minted UUID, so re-deriving the list would invalidate the
    /// selection on every redraw.
    @State private var availableEntries: [SavedWindowEntry] = []

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if availableEntries.isEmpty {
                    Text("No open windows to add")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(availableEntries) { entry in
                                let isSelected = selectedEntryIds.contains(entry.id)
                                Button {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        if isSelected {
                                            selectedEntryIds.remove(entry.id)
                                        } else {
                                            selectedEntryIds.insert(entry.id)
                                        }
                                    }
                                } label: {
                                    ZStack(alignment: .topTrailing) {
                                        WindowGroupEntryTile(entry: entry)

                                        Group {
                                            if isSelected {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .font(.title2)
                                                    .foregroundStyle(.white, Color.accentColor)
                                            } else {
                                                Image(systemName: "circle")
                                                    .font(.title2)
                                                    .foregroundStyle(.white.opacity(0.7))
                                                    .shadow(color: .black.opacity(0.5), radius: 2)
                                            }
                                        }
                                        .padding(8)
                                    }
                                }
                                .buttonStyle(.plain)
                                #if !os(macOS)
                                .hoverEffectDisabled()
                                #endif
                                .hoverEffect(LiftHoverEffect())
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Add to \(group.name)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if !availableEntries.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add (\(selectedEntryIds.count))") {
                            let toAdd = availableEntries.filter { selectedEntryIds.contains($0.id) }
                            appModel.addEntriesToWindowGroup(group, entries: toAdd)
                            dismiss()
                        }
                        .disabled(selectedEntryIds.isEmpty)
                    }
                }
            }
            .onAppear {
                availableEntries = appModel.openWindowEntriesNotInGroup(group)
            }
        }
    }
}
