/*
 Hypnos - YouTube tab (sideload builds only: `HYPNOS_YOUTUBE`)

 Search, a pasted link, and what was watched recently. Nothing signs in:
 search is YouTube's public web search, and history stays on the device.

 Choosing a video resolves it first (`YouTubeResolver`) and then opens it in
 the platform's own video player: the video window on visionOS/iOS (where
 the depth pipeline, fake 3D and SponsorBlock skips apply), a player window
 on macOS, the full-screen system player on tvOS. Resolving before opening
 rather than in the player keeps every player unaware of YouTube apart from
 refreshing an expired stream (`VideoWindowModel+YouTube`).
 */

#if HYPNOS_YOUTUBE

import DebugTrace
import SwiftUI

struct YouTubeTabView: View {
    @State private var history = YouTubeHistory.shared
    @State private var query = ""
    @State private var submittedQuery = ""
    @State private var results: [YouTubeVideoSummary] = []
    @State private var continuation: String?
    @State private var isSearching = false
    @State private var isLoadingMore = false
    @State private var searchError: String?
    @State private var resolvingID: YouTubeVideoID?
    @State private var playError: String?
    #if os(tvOS)
    @State private var presentedVideo: GalleryVideo?
    #endif
    @OpenWindowProxy private var openWindow

    private var pastedID: YouTubeVideoID? { YouTubeVideoID(parsing: query) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    #if os(tvOS)
                    tvSearchField
                    #endif
                    if let pastedID {
                        pastedLinkRow(pastedID)
                    }
                    content
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 16)
            }
            .navigationTitle("YouTube")
            #if !os(tvOS)
            .searchable(text: $query, prompt: "Search YouTube or paste a link")
            .onSubmit(of: .search) { submit() }
            #endif
            .onChange(of: query) { _, newValue in
                if newValue.isEmpty { clearSearch() }
            }
        }
        .overlay {
            if resolvingID != nil {
                ProgressView("Opening…")
                    .padding(24)
                    .background(.regularMaterial, in: .rect(cornerRadius: 16))
            }
        }
        .alert("Can't Play This Video", isPresented: Binding(get: { playError != nil }, set: { if !$0 { playError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(playError ?? "")
        }
        #if os(tvOS)
        .fullScreenCover(item: $presentedVideo) { video in
            TVVideoPlayerView(video: video)
        }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if isSearching {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
        } else if let searchError {
            ContentUnavailableView("Search Failed", systemImage: "exclamationmark.triangle", description: Text(searchError))
        } else if !submittedQuery.isEmpty {
            if results.isEmpty {
                ContentUnavailableView.search(text: submittedQuery)
            } else {
                grid(results, removable: false)
                if continuation != nil {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .onAppear { loadMore() }
                }
            }
        } else if history.videos.isEmpty {
            ContentUnavailableView(
                "Search YouTube",
                systemImage: "play.rectangle",
                description: Text("Search for a video, or paste a YouTube link into the search field.")
            )
            .padding(.top, 40)
        } else {
            HStack {
                Text("Recently Watched").font(.title2.bold())
                Spacer()
                Button("Clear", role: .destructive) { history.clear() }
            }
            grid(history.videos, removable: true)
        }
    }

    #if os(tvOS)
    /// An in-page field and an explicit Search button. The system search field
    /// `.searchable` adds on tvOS sits above a scrolling page the remote
    /// couldn't reach, so there was nothing to focus and no way to submit.
    private var tvSearchField: some View {
        HStack(spacing: 24) {
            TextField("Search YouTube or paste a link", text: $query)
                .textFieldTapTarget()
                .onSubmit { submit() }
                .submitLabel(.search)
            Button("Search") { submit() }
                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
    #endif

    private func pastedLinkRow(_ id: YouTubeVideoID) -> some View {
        Button {
            play(YouTubeVideoSummary(id: id, title: "YouTube video"))
        } label: {
            Label("Play this link", systemImage: "play.fill")
                .font(.headline)
        }
        .buttonStyle(.borderedProminent)
    }

    private func grid(_ videos: [YouTubeVideoSummary], removable: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: cardMinimumWidth), spacing: gridSpacing, alignment: .top)],
                  spacing: gridSpacing) {
            ForEach(videos) { video in
                Button { play(video) } label: { YouTubeVideoCard(video: video) }
                    #if os(tvOS)
                    .buttonStyle(.borderless)
                    #else
                    .buttonStyle(.plain)
                    #endif
                    .contextMenu {
                        Button("Play", systemImage: "play") { play(video) }
                        #if !os(tvOS)
                        Button("Copy Link", systemImage: "link") {
                            UIPasteboard.general.string = video.id.watchURL.absoluteString
                        }
                        #endif
                        if removable {
                            Button("Remove from History", systemImage: "trash", role: .destructive) {
                                history.remove(video.id)
                            }
                        }
                    }
                    .disabled(resolvingID != nil)
            }
        }
    }

    // MARK: - Search

    private func submit() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // A pasted link plays rather than searching for its URL text.
        if let id = YouTubeVideoID(parsing: text) {
            play(YouTubeVideoSummary(id: id, title: "YouTube video"))
            return
        }
        submittedQuery = text
        isSearching = true
        searchError = nil
        Task {
            defer { isSearching = false }
            do {
                let page = try await YouTubeInnertube.shared.search(text)
                guard submittedQuery == text else { return }
                results = page.results
                continuation = page.continuation
            } catch {
                guard submittedQuery == text else { return }
                AppLogger.youtube.error("Search failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
                searchError = error.localizedDescription
                results = []
                continuation = nil
            }
        }
    }

    private func loadMore() {
        guard let token = continuation, !isLoadingMore else { return }
        let text = submittedQuery
        isLoadingMore = true
        Task {
            defer { isLoadingMore = false }
            guard let page = try? await YouTubeInnertube.shared.search(text, continuation: token),
                  submittedQuery == text else {
                continuation = nil
                return
            }
            let known = Set(results.map(\.id))
            results += page.results.filter { !known.contains($0.id) }
            // A page that added nothing would only ask again forever.
            continuation = page.results.isEmpty ? nil : page.continuation
        }
    }

    private func clearSearch() {
        submittedQuery = ""
        results = []
        continuation = nil
        searchError = nil
    }

    // MARK: - Playback

    private func play(_ summary: YouTubeVideoSummary) {
        guard resolvingID == nil else { return }
        resolvingID = summary.id
        Task {
            defer { resolvingID = nil }
            do {
                let resolution = try await YouTubeResolver.resolve(summary.id)
                var recorded = summary
                if let title = resolution.video.title { recorded.title = title }
                if recorded.lengthSeconds == nil { recorded.lengthSeconds = resolution.video.duration }
                history.record(recorded)
                present(resolution.video)
            } catch {
                playError = error.localizedDescription
            }
        }
    }

    private func present(_ video: GalleryVideo) {
        #if os(tvOS)
        presentedVideo = video
        #elseif os(macOS)
        openWindow(id: "video-detail", value: video)
        #else
        openWindow(id: "video-detail", value: VideoWindowValue(video: video, galleryVideos: [video]))
        #endif
    }

    // MARK: - Metrics

    private var cardMinimumWidth: CGFloat {
        #if os(tvOS)
        400
        #else
        260
        #endif
    }

    private var gridSpacing: CGFloat {
        #if os(tvOS)
        48
        #else
        20
        #endif
    }

    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        60
        #else
        20
        #endif
    }
}

/// One video: a 16:9 thumbnail with its length, title, channel and views.
struct YouTubeVideoCard: View {
    let video: YouTubeVideoSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LibraryImage(url: video.thumbnailURL) {
                Rectangle().fill(.quaternary)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(alignment: .bottomTrailing) {
                if let length = lengthLabel {
                    Text(length)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.75), in: .rect(cornerRadius: 4))
                        .padding(6)
                }
            }
            .clipShape(.rect(cornerRadius: 12))
            #if os(tvOS)
            .hoverEffect(.highlight)
            #endif

            Text(video.title)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let byline {
                Text(byline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(.rect)
    }

    private var lengthLabel: String? {
        if let text = video.lengthText { return text }
        guard let seconds = video.lengthSeconds, seconds > 0 else { return nil }
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    private var byline: String? {
        let parts = [video.author, video.viewCountText, video.publishedText].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

#endif
