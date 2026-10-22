/*
 Hypnos - a player's title, and the details behind it

 Every player names what it plays in its top-left corner, and a tap there
 opens the details: for a Library title its series and episode, year,
 runtime, ratings, genres and overview, for a Stash scene its studio, date,
 performers, tags and description, and for anything else the file and its
 picture. Where it sits is the player's business: on visionOS an ornament
 over the window's corner (nothing SwiftUI draws reaches over a stereo
 picture), on iOS beside the close button, and on tvOS AVKit's own Info
 panel for the video player (`AVPlayerItem.externalMetadata`, filled from
 the same details) and a corner button for the film player.

 What the player knows already (`PlayerDetails(video:)`) shows at once; the
 server's fuller account replaces it when it arrives.
 */

import SwiftUI

/// Where a title's details come from.
enum PlayerDetailsSource: Hashable {
    case library(itemId: String)
    case stash(sceneId: String)
    case none

    @MainActor init(video: GalleryVideo) {
        if let itemId = LibraryPlaybackCoordinator.jellyfinItemId(fromVideoIdentity: video.identity) {
            self = .library(itemId: itemId)
        } else if let sceneId = video.stashId {
            self = .stash(sceneId: sceneId)
        } else {
            self = .none
        }
    }
}

/// What a title's details show.
struct PlayerDetails: Hashable {
    struct Row: Hashable {
        var label: String
        var value: String
    }

    var title: String
    /// Over the title: an episode's series, a scene's studio.
    var context: String?
    /// Under the title: "Season 1, Episode 3", a scene's date.
    var subtitle: String?
    /// One line of short facts: year, runtime, ratings, picture size.
    var facts: [String] = []
    var overview: String?
    var rows: [Row] = []
    /// A Library title's art comes through the library's image routes.
    var libraryItem: LibraryItem?
    var artworkURL: URL?

    /// The corner's two lines: an episode reads as its series over
    /// "S1 E3 · Title", the way the TV app shows one.
    var cornerTitle: String { libraryItem?.kind == .episode ? context ?? title : title }
    var cornerSubtitle: String? {
        guard let item = libraryItem, item.kind == .episode, context != nil else { return nil }
        return [item.episodeLabel, title].compactMap { $0 }.joined(separator: " · ")
    }
}

extension PlayerDetails {
    /// What a video window knows without asking anyone.
    @MainActor init(video: GalleryVideo) {
        self.init(title: video.title?.nilIfEmpty ?? video.fileName ?? video.streamURL.lastPathComponent)
        if let duration = video.duration, duration > 0 { facts.append(Self.runtime(duration)) }
        if let width = video.sourceWidth, let height = video.sourceHeight, width > 0, height > 0 {
            facts.append("\(width) × \(height)")
        }
        if video.isStereoscopic { facts.append("3D") }
        if let fileName = video.fileName, fileName != title { rows.append(Row(label: "File", value: fileName)) }
        if !video.streamURL.isFileURL, LibraryPlaybackCoordinator.jellyfinItemId(fromVideoIdentity: video.identity) == nil {
            artworkURL = video.thumbnailURL
        }
    }

    init(item: LibraryItem) {
        self.init(title: item.title)
        libraryItem = item
        if item.kind == .episode {
            context = item.seriesName
            if let season = item.seasonNumber, let episode = item.episodeNumber {
                subtitle = "Season \(season), Episode \(episode)"
            }
        }
        if let year = item.year { facts.append(String(year)) }
        if let runtime = item.runtimeSeconds, runtime > 0 { facts.append(Self.runtime(runtime)) }
        if let rating = item.officialRating, !rating.isEmpty { facts.append(rating) }
        if let score = item.communityRating { facts.append(String(format: "★ %.1f", score)) }
        if item.stereoFormat != nil { facts.append("3D") }
        overview = item.overview?.nilIfEmpty
        if !item.genres.isEmpty { rows.append(Row(label: "Genres", value: item.genres.joined(separator: ", "))) }
    }

    init(scene: SceneDetail, video: GalleryVideo) {
        self.init(title: scene.title?.nilIfEmpty ?? video.title?.nilIfEmpty ?? scene.filePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Video")
        context = scene.studio?.name
        subtitle = scene.date?.nilIfEmpty
        if let duration = scene.duration, duration > 0 { facts.append(Self.runtime(duration)) }
        if let width = scene.width, let height = scene.height { facts.append("\(width) × \(height)") }
        if let rating = scene.rating100 { facts.append(String(format: "★ %.1f", Double(rating) / 20)) }
        overview = scene.details?.nilIfEmpty
        if !scene.performers.isEmpty {
            rows.append(Row(label: "Performers", value: scene.performers.map(\.name).joined(separator: ", ")))
        }
        if !scene.tags.isEmpty { rows.append(Row(label: "Tags", value: scene.tags.map(\.name).joined(separator: ", "))) }
        if let director = scene.director?.nilIfEmpty { rows.append(Row(label: "Director", value: director)) }
        let picture = [scene.videoCodec?.uppercased(), scene.frameRate.map { String(format: "%.3g fps", $0) }]
            .compactMap { $0 }
        if !picture.isEmpty { rows.append(Row(label: "Picture", value: picture.joined(separator: " · "))) }
        if let path = scene.filePath { rows.append(Row(label: "File", value: URL(fileURLWithPath: path).lastPathComponent)) }
        artworkURL = video.thumbnailURL
    }

    /// The server's account of `source`, or nil when there is none to ask
    /// or it didn't answer (the corner keeps what the player knew).
    @MainActor
    static func load(_ source: PlayerDetailsSource, video: GalleryVideo?, stash: StashAPIClient?) async -> PlayerDetails? {
        switch source {
        case .library(let itemId):
            guard let library = LibraryService.current(),
                  let item = try? await library.item(id: itemId) else { return nil }
            return PlayerDetails(item: item)
        case .stash(let sceneId):
            guard let stash, let video, let scene = try? await stash.fetchSceneDetail(id: sceneId) else { return nil }
            return PlayerDetails(scene: scene, video: video)
        case .none:
            return nil
        }
    }

    static func runtime(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(max(minutes, 1)) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Loads a title's details once per source, starting from what the player
/// knows. Hosts that need the details themselves (tvOS's Info panel) read
/// `details`; the corner button keeps its own.
@MainActor @Observable
final class PlayerDetailsLoader {
    private(set) var details: PlayerDetails
    private var loaded: PlayerDetailsSource?
    /// `details` is the server's, for `loaded`.
    private var fromServer = false

    init(fallback: PlayerDetails) { details = fallback }

    func load(_ source: PlayerDetailsSource, fallback: PlayerDetails, video: GalleryVideo?, stash: StashAPIClient?) async {
        if source != loaded {
            loaded = source
            fromServer = false
        }
        guard !fromServer else { return }
        details = fallback
        if let full = await PlayerDetails.load(source, video: video, stash: stash), !Task.isCancelled, loaded == source {
            details = full
            fromServer = true
        }
    }
}

/// The title in a player's corner. A tap shows the details: a popover by
/// the title (a sheet on a phone), a sheet on tvOS, which has no popovers.
struct PlayerTitleButton: View {
    let source: PlayerDetailsSource
    /// What the player knows, shown until the server answers.
    let fallback: PlayerDetails
    var video: GalleryVideo?
    /// Bumped by the host to close the details (a tap on the picture).
    var dismissal = 0
    var onOpenChanged: (Bool) -> Void = { _ in }

    @Environment(AppModel.self) private var appModel
    @State private var loader: PlayerDetailsLoader
    @State private var showsDetails = false

    init(source: PlayerDetailsSource, fallback: PlayerDetails, video: GalleryVideo? = nil,
         dismissal: Int = 0, onOpenChanged: @escaping (Bool) -> Void = { _ in }) {
        self.source = source
        self.fallback = fallback
        self.video = video
        self.dismissal = dismissal
        self.onOpenChanged = onOpenChanged
        _loader = State(initialValue: PlayerDetailsLoader(fallback: fallback))
    }

    private var details: PlayerDetails { loader.details }

    var body: some View {
        Button { showsDetails.toggle() } label: { label }
            #if os(visionOS)
            .buttonStyle(.plain)
            .contentShape(.hoverEffect, .rect(cornerRadius: 22))
            .hoverEffect()
            .glassBackgroundEffect(in: .rect(cornerRadius: 22))
            #elseif os(iOS)
            .buttonStyle(.glass)
            #endif
            .accessibilityIdentifier("player.title")
            .accessibilityHint("Shows the details")
            .help("Details")
            #if os(tvOS)
            .sheet(isPresented: $showsDetails) {
                PlayerDetailsView(details: details).frame(width: 1100)
            }
            #else
            .popover(isPresented: $showsDetails, arrowEdge: .top) {
                PlayerDetailsView(details: details)
                    .frame(idealWidth: 460, maxWidth: 520, maxHeight: 640)
                    .presentationCompactAdaptation(.sheet)
                    .presentationDetents([.medium, .large])
                    // Taps reach the window, so one on the picture closes it.
                    .presentationBackgroundInteraction(.enabled)
            }
            #endif
            .onChange(of: showsDetails) { _, shown in onOpenChanged(shown) }
            .onChange(of: dismissal) { showsDetails = false }
            .onDisappear {
                if showsDetails { onOpenChanged(false) }
                showsDetails = false
            }
            .task(id: TaskKey(source: source, title: fallback.title)) {
                await loader.load(source, fallback: fallback, video: video, stash: appModel.apiClient)
            }
    }

    private struct TaskKey: Hashable {
        var source: PlayerDetailsSource
        var title: String
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(details.cornerTitle)
                .font(.headline)
            if let subtitle = details.cornerSubtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: 420, alignment: .leading)
        #if os(visionOS)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        #else
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        #endif
        .contentShape(.rect)
    }
}

/// The details themselves.
struct PlayerDetailsView: View {
    let details: PlayerDetails

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                artwork
                VStack(alignment: .leading, spacing: 4) {
                    if let context = details.context {
                        Text(context)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(details.title)
                        .font(.title2.weight(.bold))
                    if let subtitle = details.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if !details.facts.isEmpty {
                    Text(details.facts.joined(separator: " · "))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let overview = details.overview {
                    Text(overview)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !details.rows.isEmpty {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                        ForEach(details.rows, id: \.self) { row in
                            GridRow {
                                Text(row.label)
                                    .foregroundStyle(.secondary)
                                    .gridColumnAlignment(.trailing)
                                Text(row.value)
                                    #if !os(tvOS)
                                    .textSelection(.enabled)
                                    #endif
                            }
                        }
                    }
                    .font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .accessibilityIdentifier("player.details")
    }

    @ViewBuilder private var artwork: some View {
        if let item = details.libraryItem {
            LibraryArtwork(item: item, slot: .landscape, size: .poster, showsTitleOnFallback: false)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 12))
        } else if let url = details.artworkURL {
            LibraryImage(url: url, placeholderWhileLoading: false) { EmptyView() }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 12))
        }
    }
}
