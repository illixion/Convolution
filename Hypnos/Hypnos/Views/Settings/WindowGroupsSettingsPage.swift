/*
 Hypnos - Settings → Window Groups (visionOS)

 Save the open pop-out windows as a named group and restore them later, all
 at once or picking which (`WindowGroupRestoreSheet`).
 */

import SwiftUI

struct WindowGroupsSettingsPage: View {
    @Environment(AppModel.self) private var appModel
    @State private var showSaveGroupAlert = false
    @State private var newGroupName = ""
    @State private var showRenameGroupAlert = false
    @State private var renamingGroup: SavedWindowGroup?
    @State private var renameGroupName = ""
    @State private var restoreSheetGroup: SavedWindowGroup?

    /// Number of open windows a group would capture right now.
    private var openWindowCount: Int {
        appModel.openWindowEntries.count
    }

    var body: some View {
        SettingsPage("Window Groups") {
            Section {
                Button("Save Current Windows") {
                    newGroupName = ""
                    showSaveGroupAlert = true
                }
                .disabled(openWindowCount == 0)
            } footer: {
                Text("Saves every open pop-out window — photos, videos and slideshows — and restores each one at the size it was saved at.")
            }

            Section("Saved") {
                if appModel.savedWindowGroups.isEmpty {
                    Text("No saved window groups")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appModel.savedWindowGroups) { group in
                        row(group)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            appModel.deleteSavedWindowGroup(appModel.savedWindowGroups[index])
                        }
                    }
                }
            }
        }
        .alert("Save Window Group", isPresented: $showSaveGroupAlert) {
            TextField("Group Name", text: $newGroupName)
            Button("Save") {
                let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    appModel.saveCurrentWindowGroup(name: name)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name for this arrangement of \(openWindowCount) open \(openWindowCount == 1 ? "window" : "windows"). Each window's position is remembered by visionOS; the group remembers what it showed and how big it was.")
        }
        .alert("Rename Window Group", isPresented: $showRenameGroupAlert) {
            TextField("Group Name", text: $renameGroupName)
            Button("Rename") {
                let name = renameGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty, let group = renamingGroup {
                    appModel.renameSavedWindowGroup(group, newName: name)
                }
                renamingGroup = nil
            }
            Button("Cancel", role: .cancel) {
                renamingGroup = nil
            }
        } message: {
            Text("Enter a new name for this window group.")
        }
        .sheet(item: $restoreSheetGroup) { group in
            WindowGroupRestoreSheet(group: group)
                .environment(appModel)
        }
    }

    private func row(_ group: SavedWindowGroup) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(group.name)
                Text("\(group.contentSummary) \u{00B7} \(group.savedDate, style: .date)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Rename") {
                renamingGroup = group
                renameGroupName = group.name
                showRenameGroupAlert = true
            }
            .buttonStyle(.borderless)
            Button("Restore All") {
                appModel.restoreWindowGroup(group)
            }
            .buttonStyle(.borderless)
            Button("Restore...") {
                restoreSheetGroup = group
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
