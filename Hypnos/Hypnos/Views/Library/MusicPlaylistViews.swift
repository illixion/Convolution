/*
 Hypnos - Music section: "Add to Playlist".

 Playlists belong to a Jellyfin user, so the sheet says so when the server is set up with an API key.
 */

import SwiftUI

struct MusicPlaylistPickerSheet: View {
    let request: MusicActions.PlaylistRequest
    let actions: MusicActions
    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [JellyfinMusicItem] = []
    @State private var isLoading = true
    @State private var failure: String?
    @State private var newName = ""
    @State private var isWorking = false

    private var needsSignIn: Bool { !(LibraryService.current()?.hasUserSession ?? false) }

    var body: some View {
        NavigationStack {
            List {
                if needsSignIn {
                    Text(MusicServerError.signInRequired.localizedDescription).foregroundStyle(.secondary)
                } else {
                    Section {
                        HStack {
                            TextField("New Playlist", text: $newName)
                                .submitLabel(.done)
                                .onSubmit { Task { await create() } }
                            Button("Create") { Task { await create() } }
                                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                        }
                    }
                    Section("Playlists") {
                        if isLoading { ProgressView() }
                        else if playlists.isEmpty { Text("No playlists yet.").foregroundStyle(.secondary) }
                        ForEach(playlists) { playlist in
                            Button { Task { await add(to: playlist) } } label: {
                                HStack(spacing: 12) {
                                    MusicArtwork(item: playlist, music: .shared)
                                        .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading) {
                                        Text(playlist.Name)
                                        if let count = playlist.ChildCount { Text("\(count) songs").font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).disabled(isWorking)
                        }
                    }
                }
                if let failure { Text(failure).foregroundStyle(.red) }
            }
            .navigationTitle("Add \(request.items.count == 1 ? "“\(request.title)”" : "\(request.items.count) Songs")")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { await load() }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 420)
        #endif
    }

    private func load() async {
        guard !needsSignIn, let library = LibraryService.current() else { isLoading = false; return }
        do { playlists = try await library.musicPlaylists() } catch { failure = error.localizedDescription }
        isLoading = false
    }

    private func add(to playlist: JellyfinMusicItem) async {
        guard let library = LibraryService.current() else { return }
        isWorking = true; defer { isWorking = false }
        do {
            try await library.addToMusicPlaylist(id: playlist.id, itemIDs: request.items.map(\.id))
            MusicCatalog.shared.invalidate { $0.playlistID == playlist.id || $0.section == .playlists }
            actions.libraryChanged()
            actions.post("Added to “\(playlist.Name)”")
            dismiss()
        } catch { failure = error.localizedDescription }
    }

    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let library = LibraryService.current() else { return }
        isWorking = true; defer { isWorking = false }
        do {
            try await library.createMusicPlaylist(name: name, itemIDs: request.items.map(\.id))
            actions.libraryChanged()
            actions.post("Created “\(name)”")
            dismiss()
        } catch { failure = error.localizedDescription }
    }
}
