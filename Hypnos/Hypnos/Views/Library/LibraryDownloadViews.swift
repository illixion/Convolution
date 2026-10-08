/*
 Hypnos - Library downloads UI (visionOS, iOS, macOS)

 - `LibraryDownloadButton`: the detail page's top-right toolbar button.
   Download, then a progress ring (tap to cancel), then a filled arrow
   (tap to remove). A show or season gets a menu: all episodes, the season
   showing, remove what is downloaded.
 - `LibraryDownloadMenuItems`: the same choices in a lockup's context menu.
 - `LibraryDownloadsView`: everything downloaded or downloading, reachable
   from the Library home's toolbar, and the place to delete downloads.

 When the server doesn't allow downloads (the account's policy, or the item
 isn't a file), the button stays visible but greyed, and pressing it says
 why; the menu item is disabled with the reason under it. tvOS shows none
 of this (`LibraryDownloads.isSupported`).
 */

import SwiftUI

struct LibraryDownloadButton: View {
    let item: LibraryItem
    /// For a show: the season the page is showing, offered on its own.
    var season: LibraryItem?

    @State private var deniedReason: String?
    @State private var confirmsRemoval = false
    private var downloads: LibraryDownloads { .shared }

    var body: some View {
        switch downloads.availability(for: item) {
        case .unsupported:
            EmptyView()
        case .denied(let reason):
            Button {
                deniedReason = reason
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .foregroundStyle(.secondary)
            .help(reason)
            .alert("Can't Download", isPresented: Binding(get: { deniedReason != nil }, set: { if !$0 { deniedReason = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deniedReason ?? "")
            }
        case .available:
            if item.kind == .series || item.kind == .season {
                containerMenu
            } else {
                itemControl
            }
        }
    }

    @ViewBuilder
    private var itemControl: some View {
        if downloads.record(for: item.id) != nil {
            Menu {
                Button("Remove Download", systemImage: "trash", role: .destructive) {
                    downloads.remove(itemId: item.id)
                }
            } label: {
                Label("Downloaded", systemImage: "arrow.down.circle.fill")
            }
            .help("Downloaded")
        } else if let job = downloads.job(for: item.id) {
            Menu {
                if case .failed(let message) = job.phase {
                    Text(message)
                    Button("Try Again", systemImage: "arrow.clockwise") { downloads.retry(itemId: item.id) }
                }
                Button("Cancel Download", systemImage: "xmark", role: .destructive) {
                    downloads.cancel(itemId: item.id)
                }
            } label: {
                LibraryDownloadProgressLabel(job: job)
            }
            .help(job.detail ?? "Downloading")
        } else {
            Button {
                downloads.download(item)
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .help("Download")
        }
    }

    private var containerMenu: some View {
        let downloaded = downloads.downloadedEpisodeCount(of: item)
        return Menu {
            Button(item.kind == .season ? "Download Season" : "Download All Episodes", systemImage: "arrow.down.circle") {
                downloads.download(item)
            }
            if let season, item.kind == .series {
                Button("Download \(season.title)", systemImage: "arrow.down.circle") { downloads.download(season) }
            }
            if downloaded > 0 {
                Button("Remove \(downloaded) Downloaded Episode\(downloaded == 1 ? "" : "s")", systemImage: "trash",
                       role: .destructive) {
                    downloads.removeEpisodes(of: item)
                }
            }
        } label: {
            Label("Download", systemImage: downloaded > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
        }
        .help("Download")
    }
}

/// A download arrow inside a ring that fills as the job goes.
struct LibraryDownloadProgressLabel: View {
    let job: LibraryDownloadJob

    var body: some View {
        Label {
            Text("Downloading")
        } icon: {
            ZStack {
                Circle().stroke(.secondary.opacity(0.35), lineWidth: 2.5)
                if case .failed = job.phase {
                    Image(systemName: "exclamationmark").font(.caption.weight(.bold)).foregroundStyle(.orange)
                } else if let fraction = job.fraction {
                    Circle()
                        .trim(from: 0, to: max(0.02, fraction))
                        .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "stop.fill").font(.system(size: 7))
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .frame(width: 20, height: 20)
        }
    }
}

/// Download choices for a lockup's context menu.
struct LibraryDownloadMenuItems: View {
    let item: LibraryItem
    private var downloads: LibraryDownloads { .shared }

    var body: some View {
        switch downloads.availability(for: item) {
        case .unsupported:
            EmptyView()
        case .denied(let reason):
            Section {
                Button {} label: {
                    Label("Download", systemImage: "arrow.down.circle")
                    Text(reason)
                }
                .disabled(true)
            }
        case .available:
            Section { choices }
        }
    }

    @ViewBuilder
    private var choices: some View {
        if item.kind == .series || item.kind == .season {
            Button(item.kind == .season ? "Download Season" : "Download All Episodes", systemImage: "arrow.down.circle") {
                downloads.download(item)
            }
            let downloaded = downloads.downloadedEpisodeCount(of: item)
            if downloaded > 0 {
                Button("Remove Downloaded Episodes", systemImage: "trash", role: .destructive) {
                    downloads.removeEpisodes(of: item)
                }
            }
        } else if downloads.record(for: item.id) != nil {
            Button("Remove Download", systemImage: "trash", role: .destructive) { downloads.remove(itemId: item.id) }
        } else if let job = downloads.job(for: item.id) {
            if case .failed = job.phase {
                Button("Try Download Again", systemImage: "arrow.clockwise") { downloads.retry(itemId: item.id) }
            }
            Button("Cancel Download", systemImage: "xmark", role: .destructive) { downloads.cancel(itemId: item.id) }
        } else {
            Button("Download", systemImage: "arrow.down.circle") { downloads.download(item) }
        }
    }
}

/// The Library home's route to the Downloads list.
struct LibraryDownloadsRequest: Hashable {}

/// Toolbar button on the Library home: the Downloads list, with a ring
/// while something is downloading.
struct LibraryDownloadsToolbarButton: View {
    let open: () -> Void
    private var downloads: LibraryDownloads { .shared }

    var body: some View {
        if LibraryDownloads.isSupported, !(downloads.records.isEmpty && downloads.jobs.isEmpty) {
            Button(action: open) {
                if let job = downloads.orderedJobs.first(where: \.isActive) {
                    LibraryDownloadProgressLabel(job: job)
                } else {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }
            }
            .help("Downloads")
        }
    }
}

struct LibraryDownloadsView: View {
    let playback: LibraryPlayback
    private var downloads: LibraryDownloads { .shared }

    var body: some View {
        List {
            if downloads.isOffline {
                Section {
                    Label("You're offline. Downloads play from this device, and where you stop is sent to the server when it's back.",
                          systemImage: "wifi.slash")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if !downloads.orderedJobs.isEmpty {
                Section("Downloading") {
                    ForEach(downloads.orderedJobs) { job in
                        LibraryDownloadJobRow(job: job)
                    }
                }
            }
            let movies = downloads.records.filter { $0.item.kind != .episode }.sorted { $0.item.title < $1.item.title }
            if !movies.isEmpty {
                Section("Movies") {
                    ForEach(movies) { record in row(record) }
                }
            }
            ForEach(shows, id: \.id) { show in
                Section(show.title) {
                    ForEach(downloads.records.filter { $0.item.seriesId == show.id }.sorted(by: Self.airingOrder)) { record in
                        row(record)
                    }
                }
            }
            if !downloads.records.isEmpty {
                Section {
                } footer: {
                    Text("\(ByteCountFormatter.string(fromByteCount: downloads.records.reduce(0) { $0 + $1.bytes }, countStyle: .file)) on this device. The files are also in the Files app, under Convolution › Videos › Jellyfin.")
                }
            }
        }
        .overlay {
            if downloads.records.isEmpty && downloads.jobs.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle",
                                       description: Text("Download a movie or episode from its page or by long-pressing it."))
            }
        }
        .navigationTitle("Downloads")
        .environment(\.colorScheme, .dark)
    }

    private var shows: [LibraryItem] {
        var seen: [LibraryItem] = []
        for record in downloads.records where record.item.kind == .episode {
            let show = record.series ?? LibraryItem(id: record.item.seriesId ?? "", kind: .series,
                                                    title: record.item.seriesName ?? "Show")
            if !seen.contains(where: { $0.id == show.id }) { seen.append(show) }
        }
        return seen.sorted { $0.title < $1.title }
    }

    private static func airingOrder(_ a: LibraryOfflineRecord, _ b: LibraryOfflineRecord) -> Bool {
        (a.item.seasonNumber ?? 0, a.item.episodeNumber ?? 0) < (b.item.seasonNumber ?? 0, b.item.episodeNumber ?? 0)
    }

    private func row(_ record: LibraryOfflineRecord) -> some View {
        let item = record.displayItem
        return Button {
            Task { await playback.play(item) }
        } label: {
            HStack(spacing: 12) {
                LibraryArtwork(item: item, slot: item.kind == .episode ? .landscape : .poster)
                    .frame(width: item.kind == .episode ? 96 : 54, height: 54 * (item.kind == .episode ? 1 : 1.5))
                    .clipShape(.rect(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.episodeLabel.map { "\($0) · \(item.title)" } ?? item.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(ByteCountFormatter.string(fromByteCount: record.bytes, countStyle: .file))
                        if record.hasObjectAudio { Text("Object Audio") }
                        if let remaining = item.remainingSeconds { Text(LibraryFormat.remaining(remaining)) }
                        else if item.userData.isPlayed { Text("Watched") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if playback.resolvingItemId == item.id { ProgressView() }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Remove Download", systemImage: "trash", role: .destructive) { downloads.remove(itemId: record.id) }
        }
        #if !os(tvOS)
        .swipeActions {
            Button("Remove", systemImage: "trash", role: .destructive) { downloads.remove(itemId: record.id) }
        }
        #endif
    }
}

private struct LibraryDownloadJobRow: View {
    let job: LibraryDownloadJob
    private var downloads: LibraryDownloads { .shared }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.item.episodeLabel.map { "\(job.item.seriesName ?? "") \($0) · \(job.item.title)" } ?? job.item.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                switch job.phase {
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.orange)
                case .queued:
                    Text("Waiting").font(.caption).foregroundStyle(.secondary)
                default:
                    if let fraction = job.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    if let detail = job.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            if case .failed = job.phase {
                Button("Try Again", systemImage: "arrow.clockwise") { downloads.retry(itemId: job.id) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            Button("Cancel", systemImage: "xmark.circle.fill") { downloads.cancel(itemId: job.id) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
    }
}
