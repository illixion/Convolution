/*
 Hypnos - the YouTube tab's signed-in feeds (sideload builds only)

 Each feed is a page of YouTube's mobile site loaded in a hidden web view
 (`YouTubePageSession`); this model turns what the page shows into the
 tab's grid. The tab owns one, so the page goes away with the tab and its
 memory with it, and the feed loads again when the tab comes back, the way
 a reopened browser tab would.
 */

#if HYPNOS_YOUTUBE

import DebugTrace
import Foundation
import Observation

/// The mobile site's pages the tab can show.
enum YouTubeFeed: String, CaseIterable, Identifiable, Sendable {
    case home
    case subscriptions
    case watchLater
    case history

    var id: Self { self }

    var title: String {
        switch self {
        case .home: "Home"
        case .subscriptions: "Subscriptions"
        case .watchLater: "Watch Later"
        case .history: "History"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .subscriptions: "rectangle.stack.badge.person.crop"
        case .watchLater: "clock"
        case .history: "clock.arrow.circlepath"
        }
    }

    var url: URL {
        switch self {
        case .home: URL(string: "https://m.youtube.com/")!
        case .subscriptions: URL(string: "https://m.youtube.com/feed/subscriptions")!
        case .watchLater: URL(string: "https://m.youtube.com/playlist?list=WL")!
        case .history: URL(string: "https://m.youtube.com/feed/history")!
        }
    }
}

@MainActor
@Observable
final class YouTubeFeedModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        /// The page loaded and showed nothing.
        case empty
        case signedOut
        /// The page is waiting on the person: a dialog (the EU cookie
        /// consent, say) or a page that isn't YouTube's (a Google sign-in
        /// check). Nothing loads until it is answered.
        case needsAnswer
    }

    private(set) var feed: YouTubeFeed = .home
    private(set) var videos: [YouTubeVideoSummary] = []
    private(set) var phase: Phase = .idle
    /// Whether the page has more to load.
    private(set) var hasMore = false
    /// Where the page is now, for answering what it waits on.
    private(set) var pageURL: URL?
    /// Created on the first load; the tab hosts its page while it exists.
    private(set) var session: YouTubePageSession?

    @ObservationIgnored private var positions: [YouTubeVideoID: Int] = [:]
    @ObservationIgnored private var emptyCheck: Task<Void, Never>?
    @ObservationIgnored private var lastReload = Date.distantPast

    private static let emptyAfter: Duration = .seconds(15)

    func show(_ feed: YouTubeFeed) {
        self.feed = feed
        guard YouTubeAccount.shared.isSignedIn == true else {
            clear()
            phase = .signedOut
            return
        }
        reload()
    }

    func reload() {
        guard YouTubeAccount.shared.isSignedIn == true else {
            show(feed)
            return
        }
        clear()
        phase = .loading
        lastReload = Date()
        let session = session ?? makeSession()
        session.load(feed.url)
        let loaded = feed
        emptyCheck = Task { [weak self] in
            try? await Task.sleep(for: Self.emptyAfter)
            guard let self, !Task.isCancelled, feed == loaded, phase == .loading else { return }
            phase = .empty
        }
    }

    /// Brings the page's "load more" marker into view. Safe to call again
    /// while a batch is on its way: it only scrolls.
    func loadMore() {
        guard hasMore, phase == .loaded else { return }
        session?.loadMore()
    }

    private func clear() {
        emptyCheck?.cancel()
        videos = []
        positions = [:]
        hasMore = false
    }

    private func makeSession() -> YouTubePageSession {
        let session = YouTubePageSession()
        session.onPayload = { [weak self] payload in self?.receive(payload) }
        session.onPageFinished = { [weak self] url in self?.pageFinished(url) }
        session.onPageLost = { [weak self] in self?.pageLost() }
        self.session = session
        return session
    }

    private func receive(_ payload: YouTubePageScript.Payload) {
        guard phase != .idle, phase != .signedOut else { return }
        if payload.loggedIn == false {
            YouTubeAccount.shared.pageReportedSignedOut()
            clear()
            phase = .signedOut
            return
        }
        if let hasMore = payload.hasMore { self.hasMore = hasMore }
        for card in payload.cards {
            guard let summary = card.summary else { continue }
            if let position = positions[summary.id] {
                videos[position] = summary
            } else {
                positions[summary.id] = videos.count
                videos.append(summary)
            }
        }
        if payload.dialog == true {
            phase = .needsAnswer
        } else if !videos.isEmpty {
            phase = .loaded
        } else if phase == .needsAnswer {
            phase = .loading
        }
    }

    private func pageFinished(_ url: URL?) {
        pageURL = url
        guard phase != .signedOut else { return }
        if !YouTubeAccount.isYouTubePage(url) {
            AppLogger.youtube.notice("YouTube feed page went elsewhere and waits for an answer")
            phase = .needsAnswer
        }
    }

    /// The web process died; load the page again, unless it keeps dying.
    private func pageLost() {
        guard phase == .loading || phase == .loaded, Date().timeIntervalSince(lastReload) > 10 else { return }
        reload()
    }
}

extension YouTubePageScript.Payload.Card {
    var summary: YouTubeVideoSummary? {
        guard let id = YouTubeVideoID(id) else { return nil }
        let rest = metadata ?? []
        return YouTubeVideoSummary(
            id: id,
            title: title,
            author: channel,
            lengthText: duration,
            lengthSeconds: duration.flatMap(YouTubeInnertube.seconds(fromClock:)),
            viewCountText: rest.first,
            publishedText: rest.count > 1 ? rest.dropFirst().joined(separator: " · ") : nil
        )
    }
}

#endif
