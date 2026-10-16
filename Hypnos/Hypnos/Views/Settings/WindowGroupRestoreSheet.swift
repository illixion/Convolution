/*
 Hypnos - Window Group Restore Sheet

 Grid of the windows in a saved group — photos, videos and slideshows alike.
 Supports restoring one at a time (each at the size it
 was saved at), multi-select delete, and adding currently-open windows.
 */

import SwiftUI

struct WindowGroupRestoreSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @DismissWindowProxy private var dismissWindow

    let group: SavedWindowGroup
    @State private var restoredEntryIds: Set<UUID> = []
    @State private var showAddSheet = false
    @State private var isSelectionMode = false
    @State private var selectedEntryIds: Set<UUID> = []
    @State private var pendingDuplicateEntry: SavedWindowEntry? = nil
    @State private var showDuplicateWindowAlert = false

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12)
    ]

    /// Re-read from AppModel each pass so deletes and additions land live.
    private var entries: [SavedWindowEntry] {
        appModel.savedWindowGroups.first { $0.id == group.id }?.entries ?? []
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(entries) { entry in
                        ZStack(alignment: .topTrailing) {
                            Button {
                                handleTap(on: entry)
                            } label: {
                                WindowGroupEntryTile(entry: entry)
                                    .opacity(restoredEntryIds.contains(entry.id) ? 0.5 : 1.0)
                            }
                            .buttonStyle(.plain)
                            #if !os(macOS)
                            .hoverEffectDisabled()
                            #endif
                            .hoverEffect(LiftHoverEffect())

                            if isSelectionMode {
                                ZStack {
                                    Circle()
                                        .fill(selectedEntryIds.contains(entry.id) ? Color.accentColor : Color.secondary.opacity(0.3))
                                    Image(systemName: selectedEntryIds.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(.white)
                                        .font(.title3)
                                }
                                .frame(width: 32, height: 32)
                                .padding(8)
                            }
                        }
                    }

                    if !isSelectionMode {
                        Button {
                            showAddSheet = true
                        } label: {
                            ZStack {
                                Color.secondary.opacity(0.2)
                                Image(systemName: "plus")
                                    .font(.largeTitle)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: WindowGroupEntryTile.side, height: WindowGroupEntryTile.side)
                            .cornerRadius(12)
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
            .sheet(isPresented: $showAddSheet) {
                AddFromOpenWindowsSheet(group: group)
                    .environment(appModel)
            }
            .alert(
                "Window Already Open",
                isPresented: $showDuplicateWindowAlert
            ) {
                Button("Summon") {
                    if let entry = pendingDuplicateEntry {
                        summonExistingWindow(for: entry)
                        restoredEntryIds.insert(entry.id)
                        pendingDuplicateEntry = nil
                    }
                }
                Button("Open New") {
                    if let entry = pendingDuplicateEntry {
                        appModel.restoreWindowEntry(entry, bypassDuplicatePrompt: true)
                        restoredEntryIds.insert(entry.id)
                        pendingDuplicateEntry = nil
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingDuplicateEntry = nil
                }
            } message: {
                Text("A window for this is already open. You can summon it to your current position or open another window.")
            }
            .navigationTitle(group.name)
            .toolbar {
                ToolbarItem(placement: {
                    #if os(macOS)
                    return ToolbarItemPlacement.automatic
                    #else
                    return ToolbarItemPlacement.topBarLeading
                    #endif
                }()) {
                    Button {
                        isSelectionMode.toggle()
                        selectedEntryIds.removeAll()
                    } label: {
                        Image(systemName: isSelectionMode ? "pencil.circle.fill" : "pencil.circle")
                            .font(.title2)
                            .symbolRenderingMode(.monochrome)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .accessibilityLabel(isSelectionMode ? "Exit selection mode" : "Enter selection mode")
                    .accessibilityHint("Toggles multi-select mode")
                    .contentShape(Circle())
                }

                ToolbarItem(placement: {
                    #if os(macOS)
                    return ToolbarItemPlacement.automatic
                    #else
                    return ToolbarItemPlacement.topBarTrailing
                    #endif
                }()) {
                    if isSelectionMode {
                        Button(role: .destructive) {
                            appModel.removeEntriesFromWindowGroup(group, entryIds: selectedEntryIds)
                            selectedEntryIds.removeAll()
                            isSelectionMode = false

                            // Removing the last entry deletes the group itself.
                            if entries.isEmpty {
                                dismiss()
                            }
                        } label: {
                            Text("Delete")
                                .font(.title3)
                        }
                        .buttonStyle(.bordered)
                        .disabled(selectedEntryIds.isEmpty)
                    } else {
                        Button {
                            dismiss()
                        } label: {
                            Text("Done")
                                .font(.title3)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func handleTap(on entry: SavedWindowEntry) {
        if isSelectionMode {
            if selectedEntryIds.contains(entry.id) {
                selectedEntryIds.remove(entry.id)
            } else {
                selectedEntryIds.insert(entry.id)
            }
            return
        }

        if appModel.hasOpenWindow(for: entry) {
            pendingDuplicateEntry = entry
            showDuplicateWindowAlert = true
        } else {
            appModel.restoreWindowEntry(entry)
            restoredEntryIds.insert(entry.id)
        }
    }

    /// Bring the already-open window to the user's current position. Dismissing
    /// the existing scene and re-opening the same window value is what actually
    /// re-places it; re-opening alone leaves it where it was.
    private func summonExistingWindow(for entry: SavedWindowEntry) {
        switch entry.kind {
        case .photo:
            guard let image = entry.image else { return }
            for value in appModel.popOutWindowValues(for: image.fullSizeURL) {
                dismissWindow(id: "photo-detail", value: value)
            }
        case .video:
            guard let video = entry.video else { return }
            for value in appModel.videoWindowValues(for: video) {
                dismissWindow(id: "video-detail", value: value)
            }
        case .remote:
            guard let configId = entry.remoteConfigId else { return }
            for value in appModel.remoteViewerWindowValues(for: configId) {
                dismissWindow(id: "remote-viewer", value: value)
            }
        case .unknown:
            return
        }
        appModel.restoreWindowEntry(entry, bypassDuplicatePrompt: true)
    }
}
