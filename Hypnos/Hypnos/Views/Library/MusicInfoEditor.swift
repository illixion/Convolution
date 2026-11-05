/*
 Hypnos - Music section: Get Info, the administrator's metadata editor.

 What this edits is Jellyfin's database, not the audio file: the file's tags and modification time stay as they
 were (measured on 12.2). Two things follow, and the sheet is built around them:
 - A refresh or library scan re-reads the file and undoes an edit, unless the item is locked. "Keep my edits"
   sets `LockData`, which protects every field (year, track number and artists included).
 - Fields the file never had (a comment, a sort title) survive a plain re-read, so "Re-read From Files" clears
   the fields this sheet owns before refreshing.
 The sheet edits the item as the server holds it and changes only the fields that were touched, so what it
 doesn't know about is sent back untouched.
 */

import SwiftUI

struct MusicInfoEditorSheet: View {
    let item: JellyfinMusicItem
    let actions: MusicActions
    @Environment(\.dismiss) private var dismiss

    private struct Draft: Equatable {
        var name = ""
        var sortName = ""
        var artists = ""
        var albumArtist = ""
        var album = ""
        var composer = ""
        var genres = ""
        var year = ""
        var track = ""
        var disc = ""
        var tags = ""
        var comment = ""
    }

    @State private var draft = Draft()
    @State private var initial = Draft()
    @State private var document: [String: Any] = [:]
    @State private var keepEdits = true
    @State private var phase = Phase.loading
    @State private var confirmingRevert = false
    @State private var isWorking = false

    private enum Phase: Equatable { case loading, ready, failed(String) }

    private var isSong: Bool { item.isSong }
    private var isAlbum: Bool { item.Type == "MusicAlbum" }
    private var isArtist: Bool { item.Type == "MusicArtist" }
    private var changed: Bool { draft != initial }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message): ContentUnavailableView("Can't Edit", systemImage: "exclamationmark.triangle", description: Text(message))
                case .ready: form
                }
            }
            .navigationTitle(item.Name)
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(phase != .ready || !changed || isWorking)
                }
            }
            .task { await load() }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
        .confirmationDialog("Re-read “\(item.Name)” from its file?", isPresented: $confirmingRevert, titleVisibility: .visible) {
            Button("Discard My Edits", role: .destructive) { Task { await revert() } }
        } message: { Text("Your edits to this \(isSong ? "song" : isAlbum ? "album" : "artist") are replaced by what the file says.") }
    }

    private var form: some View {
        Form {
            Section("Details") {
                field("Title", $draft.name)
                if isSong {
                    field("Artists", $draft.artists, prompt: "Separate with ;")
                    field("Album Artist", $draft.albumArtist)
                    field("Album", $draft.album)
                    field("Composer", $draft.composer, prompt: "Separate with ;")
                } else if isAlbum {
                    field("Album Artist", $draft.albumArtist)
                }
                if !isArtist {
                    field("Year", $draft.year, numeric: true)
                }
                if isSong {
                    field("Track", $draft.track, numeric: true)
                    field("Disc", $draft.disc, numeric: true)
                }
                field("Genres", $draft.genres, prompt: "Separate with ;")
                field("Tags", $draft.tags, prompt: "Separate with ;")
            }
            Section("Sorting") {
                field("Sort Title", $draft.sortName, prompt: "Leave empty to sort by title")
            }
            Section(isSong ? "Comment" : "Description") {
                TextField(isSong ? "Comment" : "Description", text: $draft.comment, axis: .vertical).lineLimit(3...8)
            }
            Section {
                Toggle("Keep my edits when the library rescans", isOn: $keepEdits)
                Button("Re-read From File…", role: .destructive) { confirmingRevert = true }.disabled(isWorking)
                Button("Refresh Metadata") { Task { await refresh() } }.disabled(isWorking)
            } footer: {
                Text("Edits are saved on your Jellyfin server. The audio file itself isn't changed, so other apps that read the file won't see them.")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func field(_ title: String, _ text: Binding<String>, prompt: String? = nil, numeric: Bool = false) -> some View {
        TextField(title, text: text, prompt: prompt.map { Text($0) })
            #if os(iOS) || os(visionOS)
            .keyboardType(numeric ? .numberPad : .default)
            #endif
    }

    // MARK: Loading

    private static let none = "00000000-0000-0000-0000-000000000000"

    private static func list(_ text: String) -> [String] {
        text.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func load() async {
        guard actions.isAdministrator else { phase = .failed(MusicServerError.notAdministrator.localizedDescription); return }
        guard let library = LibraryService.current() else { phase = .failed("Configure Jellyfin in Settings first."); return }
        do {
            let data = try await library.musicEditableItem(id: item.id)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MusicServerError.notAdministrator }
            document = object
            var loaded = Draft()
            loaded.name = object["Name"] as? String ?? ""
            loaded.sortName = object["ForcedSortName"] as? String ?? ""
            loaded.artists = ((object["ArtistItems"] as? [[String: Any]])?.compactMap { $0["Name"] as? String } ?? (object["Artists"] as? [String]) ?? []).joined(separator: "; ")
            loaded.albumArtist = ((object["AlbumArtists"] as? [[String: Any]])?.compactMap { $0["Name"] as? String }.first) ?? object["AlbumArtist"] as? String ?? ""
            loaded.album = object["Album"] as? String ?? ""
            loaded.composer = ((object["People"] as? [[String: Any]]) ?? []).filter { $0["Type"] as? String == "Composer" }.compactMap { $0["Name"] as? String }.joined(separator: "; ")
            loaded.genres = (object["Genres"] as? [String] ?? []).joined(separator: "; ")
            loaded.tags = (object["Tags"] as? [String] ?? []).joined(separator: "; ")
            loaded.year = (object["ProductionYear"] as? Int).map(String.init) ?? ""
            loaded.track = (object["IndexNumber"] as? Int).map(String.init) ?? ""
            loaded.disc = (object["ParentIndexNumber"] as? Int).map(String.init) ?? ""
            loaded.comment = object["Overview"] as? String ?? ""
            draft = loaded; initial = loaded
            keepEdits = object["LockData"] as? Bool ?? true
            phase = .ready
        } catch JellyfinHTTP.Failure.http(403) {
            phase = .failed(MusicServerError.notAdministrator.localizedDescription)
        } catch { phase = .failed(error.localizedDescription) }
    }

    // MARK: Saving

    private func save() async {
        guard let library = LibraryService.current() else { return }
        isWorking = true; defer { isWorking = false }
        var object = document
        if draft.name != initial.name { object["Name"] = draft.name }
        if draft.sortName != initial.sortName { object["ForcedSortName"] = draft.sortName }
        if draft.genres != initial.genres { object["Genres"] = Self.list(draft.genres) }
        if draft.tags != initial.tags { object["Tags"] = Self.list(draft.tags) }
        if draft.comment != initial.comment { object["Overview"] = draft.comment }
        if draft.year != initial.year { object["ProductionYear"] = Int(draft.year) ?? NSNull() }
        if draft.track != initial.track { object["IndexNumber"] = Int(draft.track) ?? NSNull() }
        if draft.disc != initial.disc { object["ParentIndexNumber"] = Int(draft.disc) ?? NSNull() }
        if draft.album != initial.album { object["Album"] = draft.album }
        if draft.artists != initial.artists {
            let names = Self.list(draft.artists)
            object["Artists"] = names
            object["ArtistItems"] = names.map { ["Name": $0, "Id": Self.none] }
        }
        if draft.albumArtist != initial.albumArtist {
            let name = draft.albumArtist.trimmingCharacters(in: .whitespaces)
            object["AlbumArtist"] = name
            object["AlbumArtists"] = name.isEmpty ? [] : [["Name": name, "Id": Self.none]]
        }
        if draft.composer != initial.composer {
            var people = (object["People"] as? [[String: Any]] ?? []).filter { $0["Type"] as? String != "Composer" }
            people += Self.list(draft.composer).map { ["Name": $0, "Type": "Composer", "Role": ""] }
            object["People"] = people
        }
        object["LockData"] = keepEdits
        do {
            try await library.saveMusicItem(id: item.id, json: try JSONSerialization.data(withJSONObject: object))
            actions.libraryChanged(namesChanged: true)
            actions.post("Saved “\(draft.name)”")
            dismiss()
        } catch JellyfinHTTP.Failure.http(403) {
            phase = .failed(MusicServerError.notAdministrator.localizedDescription)
        } catch { actions.post(error.localizedDescription) }
    }

    private func refresh() async {
        guard let library = LibraryService.current() else { return }
        isWorking = true; defer { isWorking = false }
        do {
            try await library.refreshMusicMetadata(id: item.id, replaceAll: false)
            actions.post(keepEdits ? "Refreshing. Your edits stay." : "Refreshing from the file…")
            try? await Task.sleep(for: .seconds(2))
            actions.libraryChanged(namesChanged: true)
        } catch { actions.post(error.localizedDescription) }
    }

    private func revert() async {
        guard let library = LibraryService.current() else { return }
        isWorking = true; defer { isWorking = false }
        do {
            // Unlock, and empty what a file might never have had, then let the file speak.
            var object = document
            object["LockData"] = false
            object["LockedFields"] = []
            object["Overview"] = ""
            object["ForcedSortName"] = ""
            object["Tags"] = [String]()
            try await library.saveMusicItem(id: item.id, json: try JSONSerialization.data(withJSONObject: object))
            try await library.refreshMusicMetadata(id: item.id, replaceAll: true)
            actions.post("Re-reading “\(item.Name)” from its file…")
            try? await Task.sleep(for: .seconds(3))
            actions.libraryChanged(namesChanged: true)
            dismiss()
        } catch { actions.post(error.localizedDescription) }
    }
}
