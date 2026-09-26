/*
 Hypnos - Library feature: shared minimal home screen

 A plain list of shelves and their item counts, used by every platform's
 Library tab for now — the real per-platform designs (tvOS's hero+focus
 carousel first, then visionOS/iOS/macOS) replace this view per platform in
 later passes, on top of the same `LibraryHomeViewModel`/`MediaServerLibrary`
 this proves out end to end: real network data, loading/empty/error states,
 pull-to-refresh.
 */

import SwiftUI

struct LibraryHomePlaceholderView: View {
    @State private var model = LibraryHomeViewModel()

    var body: some View {
        content
            .task { await model.start() }
            .refreshable { await model.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.home == nil {
            ProgressView("Loading Library…")
        } else if let error = model.error, model.home == nil {
            ContentUnavailableView("Can't Load Library", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if let home = model.home {
            List {
                if let hero = home.hero {
                    Section("Featured") {
                        row(for: hero)
                    }
                }
                ForEach(home.shelves) { shelf in
                    Section(shelf.title) {
                        if shelf.items.isEmpty {
                            Text("Nothing here yet").foregroundStyle(.secondary)
                        } else {
                            ForEach(shelf.items) { item in
                                row(for: item)
                            }
                        }
                    }
                }
                if home.shelves.isEmpty && home.hero == nil {
                    ContentUnavailableView("Library Is Empty", systemImage: "tv", description: Text("Nothing has been added to this Jellyfin server yet."))
                }
            }
        } else {
            ContentUnavailableView("No Server", systemImage: "server.rack", description: Text("Set a Jellyfin server in Settings."))
        }
    }

    private func row(for item: LibraryItem) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(item.title)
                if let subtitle = item.episodeLabel ?? item.year.map(String.init) {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if item.userData.isPlayed {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
            } else if let pct = item.userData.playedPercentage, pct > 0 {
                Text("\(Int(pct))%").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
