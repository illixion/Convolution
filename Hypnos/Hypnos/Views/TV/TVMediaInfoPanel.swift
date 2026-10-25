/*
 Hypnos - tvOS picture info and rating

 What the photo viewer shows when Select is pressed: the read-only half of
 `MediaDetailSheet` (title, date, the file's format, size and picture, the
 studio, performers, tags and galleries) and the picture's rating, set with
 the remote from a row of stars. A Stash picture's details come from the
 server (`StashAPIClient.fetchImageDetail`) and a rating goes back the way
 the grids' quick actions send one (`AppModel.updateImageRating`), so the
 grid shows it too. Any other picture shows its name and where it is from.

 Videos need none of this: the player's own Info panel already lists a Stash
 scene's details, and its transport bar has a Rating menu
 (`TVVideoPlayerView`).
 */

#if os(tvOS)

import DebugTrace
import SwiftUI

struct TVMediaInfoPanel: View {
    let image: GalleryImage
    @Environment(AppModel.self) private var appModel
    @State private var detail: ImageDetail?
    @State private var failed = false
    /// 0 is no rating; 1-5 stars.
    @State private var stars = 0
    @State private var isSaving = false
    /// The viewer behind stops taking focus while the panel shows; the
    /// rating's star is given it.
    @FocusState private var focusedStar: Int?

    private var stashId: String? { image.stashId }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                if !facts.isEmpty {
                    Text(facts.joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            if stashId != nil {
                if let detail {
                    associations(detail)
                } else if failed {
                    Text("The details couldn't be loaded.").foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
                ratingRow
            } else {
                Text(sourceLine).foregroundStyle(.secondary)
            }
        }
        .padding(40)
        .frame(maxWidth: 1400, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 32))
        .task(id: image.identity) { await load() }
    }

    // MARK: Content

    private var title: String {
        detail?.title?.tvNonEmpty ?? image.title?.tvNonEmpty ?? image.fileName
            ?? image.fullSizeURL.deletingPathExtension().lastPathComponent
    }

    /// Date, picture, format and size, as far as known.
    private var facts: [String] {
        var facts: [String] = []
        if let date = detail?.date?.tvNonEmpty { facts.append(date) }
        if let width = detail?.width ?? image.sourceWidth, let height = detail?.height ?? image.sourceHeight {
            facts.append("\(width) × \(height)")
        }
        if let format = detail?.format?.tvNonEmpty { facts.append(format.uppercased()) }
        if let size = detail?.fileSize, size > 0 {
            facts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        return facts
    }

    private var sourceLine: String {
        switch image.source {
        case .local: "A file in this Apple TV's Local library."
        case .photos: "From your photo library."
        default: "From \(appModel.effectiveLibrarySource.displayName)."
        }
    }

    @ViewBuilder
    private func associations(_ detail: ImageDetail) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 24, verticalSpacing: 10) {
            if let photographer = detail.photographer?.tvNonEmpty { row("Photographer", photographer) }
            if let studio = detail.studio { row("Studio", studio.name) }
            if !detail.performers.isEmpty { row("Performers", detail.performers.map(\.name).joined(separator: ", ")) }
            if !detail.tags.isEmpty { row("Tags", detail.tags.map(\.name).joined(separator: ", ")) }
            let galleries = detail.galleries.compactMap(\.title).filter { !$0.isEmpty }
            if !galleries.isEmpty { row("Galleries", galleries.joined(separator: ", ")) }
            if let oCounter = detail.oCounter, oCounter > 0 { row("Activity", "\(oCounter)") }
            if let file = detail.filePath { row("File", URL(fileURLWithPath: file).lastPathComponent) }
        }
        if let details = detail.details?.tvNonEmpty {
            Text(details)
                .font(.callout)
                .lineLimit(3)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).lineLimit(2)
        }
        .font(.callout)
    }

    /// Five stars, one button each; the lit one again clears the rating.
    private var ratingRow: some View {
        HStack(spacing: 16) {
            Text("Rating").foregroundStyle(.secondary)
            ForEach(1 ... 5, id: \.self) { star in
                Button {
                    rate(star == stars ? 0 : star)
                } label: {
                    Image(systemName: star <= stars ? "star.fill" : "star")
                        .foregroundStyle(star <= stars ? .yellow : .primary)
                }
                .focused($focusedStar, equals: star)
                .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
            }
            Button("No Rating") { rate(0) }
                .disabled(stars == 0)
            if isSaving { ProgressView() }
        }
        .onAppear {
            DispatchQueue.main.async { focusedStar = max(stars, 1) }
        }
    }

    // MARK: Loading and rating

    private func load() async {
        stars = Self.stars(image.rating100)
        guard let stashId else { return }
        do {
            let loaded = try await appModel.apiClient.fetchImageDetail(id: stashId)
            guard !Task.isCancelled else { return }
            detail = loaded
            stars = Self.stars(loaded.rating100)
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
            AppLogger.views.error("[tvOS] Picture details failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
        }
    }

    private func rate(_ newStars: Int) {
        guard let stashId, newStars != stars, !isSaving else { return }
        let previous = stars
        stars = newStars
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await appModel.updateImageRating(stashId: stashId, rating100: newStars == 0 ? nil : newStars * 20)
                AppLogger.views.info("[tvOS] Rated a picture \(newStars, privacy: .public) stars")
            } catch {
                stars = previous
                AppLogger.views.error("[tvOS] Rating failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            }
        }
    }

    /// Stash ratings are 0-100 in steps of 20 for five stars.
    private static func stars(_ rating100: Int?) -> Int {
        Int((Double(rating100 ?? 0) / 20).rounded())
    }
}

private extension String {
    /// Nil for an empty string, as Stash sends unset fields.
    var tvNonEmpty: String? { isEmpty ? nil : self }
}

/// A Stash scene's rating as the player's Rating menu shows and sets it.
@MainActor
@Observable
final class TVSceneRating {
    let sceneId: String
    /// The video's identity in the grid, which shows the rating too.
    let identity: String
    /// 0 is no rating; 1-5 stars.
    private(set) var stars: Int
    @ObservationIgnored weak var appModel: AppModel?

    init(sceneId: String, identity: String, rating100: Int?) {
        self.sceneId = sceneId
        self.identity = identity
        stars = Int((Double(rating100 ?? 0) / 20).rounded())
    }

    func rate(_ newStars: Int) {
        guard newStars != stars, let appModel else { return }
        let previous = stars
        stars = newStars
        let rating100 = newStars == 0 ? nil : newStars * 20
        Task {
            do {
                try await appModel.apiClient.updateSceneRating(sceneId: sceneId, rating100: rating100)
                appModel.applyVideoRating(rating100, identity: identity)
                AppLogger.views.info("[tvOS] Rated a video \(newStars, privacy: .public) stars")
            } catch {
                stars = previous
                AppLogger.views.error("[tvOS] Rating failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            }
        }
    }
}

#endif
