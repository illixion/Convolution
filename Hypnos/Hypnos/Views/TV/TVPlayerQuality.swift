/*
 Hypnos - tvOS player: the Quality menu

 What the transport bar's Quality menu offers and does, for the two kinds of
 stream whose quality can change:

 - **A Library title** streaming from Jellyfin: the same levels and rules as
   the video window (`VideoWindowModel+StreamQuality`): Auto, Always Direct
   Play and the capped levels `LibraryStreamQuality.offered` keeps for the
   title's own picture and bitrate. A pick is saved for every title
   (`LibraryStreamQuality.preferred`) and swaps the stream at the playhead.
   Under Auto the player's own buffering is watched (`StreamStallMonitor`,
   fed by `TVVideoPlayerView`'s coordinator): a stream that doesn't start, or
   keeps stalling, steps down a level, and the picture says so.
 - **A YouTube video** (sideload builds only, `HYPNOS_YOUTUBE`): Auto and the
   renditions its master offers. A chosen one plays a copy of the master
   holding only it (`YouTubeRenditions.publish`), as in the video window, so
   the player can't wander off it by bandwidth.

 A new stream reaches the player through `onSwitch`; the player swaps it in
 at the playhead and holds that position until the new item has landed, so
 a quality change never reports a reset to the server. A Jellyfin quality
 change keeps the item's play session bookkeeping in `JellyfinLibrary`
 (`streamPlan` renews it and ends the old transcode), and progress keeps
 going to the same item.
 */

#if os(tvOS)

import DebugTrace
import Foundation

@MainActor
@Observable
final class TVPlayerQuality {
    /// Plays a new stream from the playhead. Set by the player view.
    @ObservationIgnored var onSwitch: (URL) -> Void = { _ in }

    /// The stream playing now, as the player view last set it.
    var streamURL: URL?

    /// A line over the picture after Auto changed something (or couldn't).
    private(set) var notice: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init(video: GalleryVideo) {
        fileName = video.fileName
        if let itemId = LibraryPlaybackCoordinator.jellyfinItemId(fromVideoIdentity: video.identity),
           !video.streamURL.isFileURL {
            libraryItemId = itemId
        }
        #if HYPNOS_YOUTUBE
        isYouTube = YouTubeVideoID(videoIdentity: video.identity) != nil
        #endif
    }

    /// Whether there is anything to choose: a Library stream, or a YouTube
    /// master whose renditions have been read.
    var offersChoice: Bool {
        #if HYPNOS_YOUTUBE
        if isYouTube { return !youTubeRenditions.isEmpty }
        #endif
        return libraryItemId != nil
    }

    // MARK: - Library

    /// The Jellyfin item, for a server stream (a download plays as it is).
    private(set) var libraryItemId: String?
    /// The file's name, for the on-device remux of an original MKV.
    private let fileName: String?
    private(set) var preference: LibraryStreamQuality = .preferred
    private(set) var source: LibrarySourcePicture?
    @ObservationIgnored private var sourceBitrate: Int?
    private(set) var isChanging = false
    @ObservationIgnored private var stallMonitor = StreamStallMonitor()
    @ObservationIgnored private var isBuffering = false
    @ObservationIgnored private var stallPoll: Task<Void, Never>?
    @ObservationIgnored private var startupWatch: Task<Void, Never>?
    @ObservationIgnored private var switchTask: Task<Void, Never>?
    /// A frame of the stream has shown.
    @ObservationIgnored private var hasPresentedVideo = false

    /// The capped level playing; nil is the original.
    var level: LibraryStreamQuality? {
        streamURL.flatMap(LibraryStreamQuality.level(ofStream:))
    }

    /// The levels the menu lists for this title.
    var offered: [LibraryStreamQuality] {
        LibraryStreamQuality.offered(sourceWidth: source?.width, sourceHeight: source?.height,
                                     sourceBitrate: source?.bitrate)
    }

    /// The level the menu checks: the preference, or the original when this
    /// title doesn't offer it (a "4K" preference on a 1080p film).
    var checked: LibraryStreamQuality {
        offered.contains(preference) ? preference : .original
    }

    /// What the menu says under a level: the original's own picture where known.
    func detail(of quality: LibraryStreamQuality) -> String? {
        guard let label = source?.classLabel else { return quality.detail }
        switch quality {
        case .auto: return "Original \(label), lowered if the stream can't keep up"
        case .original: return "Original \(label), never lowered"
        default: return quality.detail
        }
    }

    /// What is playing, short ("720p", "Original · 1080p").
    var libraryLabel: String {
        if let level { return level.shortTitle }
        return "Original" + (source?.classLabel.map { " · \($0)" } ?? "")
    }

    /// Asks the server for the title's own picture, and starts the startup
    /// watch under Auto.
    func start() async {
        guard let itemId = libraryItemId else { return }
        armStartupWatch()
        guard let library = LibraryService.current(),
              let picture = await library.sourcePicture(itemId: itemId) else { return }
        source = picture
        sourceBitrate = picture.bitrate
        AppLogger.videoWindow.info("[tvOS] Source picture \(picture.width ?? 0, privacy: .public)×\(picture.height ?? 0, privacy: .public), \((picture.bitrate ?? 0) / 1000, privacy: .public) kbps; offering \(self.offered.map(\.rawValue).joined(separator: ", "), privacy: .public)")
    }

    /// The viewer picked `quality`: remembered for every title, and played
    /// now if it changes what plays.
    func choose(_ quality: LibraryStreamQuality) {
        guard quality != preference else { return }
        preference = quality
        LibraryStreamQuality.preferred = quality
        dismissNotice()
        let target: LibraryStreamQuality? = quality.maxBitrate == nil ? nil : quality
        guard target != level else { return }
        switchStream(to: target, reason: "chosen")
    }

    /// Replaces the stream with one at `level` (nil: the original).
    private func switchStream(to target: LibraryStreamQuality?, reason: String, notice: String? = nil) {
        guard let itemId = libraryItemId, let library = LibraryService.current() else { return }
        isChanging = true
        switchTask?.cancel()
        switchTask = Task { [weak self] in
            defer { self?.isChanging = false }
            do {
                let plan = try await library.streamPlan(itemId: itemId, quality: target ?? .original)
                guard !Task.isCancelled, let self else { return }
                self.sourceBitrate = plan.sourceBitrate ?? self.sourceBitrate
                var url = plan.streamURL
                // An original the player can't open (a WebM, or an MKV with
                // Play MKV Files on This Device): remuxed on the device, else
                // its full-quality transcode, as the player's first open does.
                let isFile = JellyfinLibrary.isFileStream(url)
                if plan.transcodeURL != nil || isFile {
                    let original = MediaAuthorization.shared.authorizedURL(url)
                    if !(await NativeVideoDecodeProbe.canPlayNatively(url: original, timeout: 5)) {
                        if isFile, let remuxed = await MatroskaRemuxService.shared.playlistURL(
                            for: original, fileName: self.fileName) {
                            url = remuxed
                        } else if let reserve = plan.transcodeURL {
                            url = reserve
                        }
                    }
                }
                guard !Task.isCancelled, url != self.streamURL else { return }
                AppLogger.videoWindow.info("[tvOS] Switching to \(target?.rawValue ?? "original", privacy: .public) quality (\(reason, privacy: .public))")
                self.stallMonitor.noteStepped(at: .now)
                self.onSwitch(url)
                if let notice { self.showNotice(notice) }
                if !self.hasPresentedVideo { self.armStartupWatch() }
            } catch {
                guard let self, !Task.isCancelled else { return }
                AppLogger.videoWindow.error("[tvOS] Quality change failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
                self.showNotice("Couldn't change quality")
            }
        }
    }

    // MARK: Auto

    private var adapts: Bool {
        libraryItemId != nil && preference == .auto && !isChanging
    }

    /// The player's waiting state: true while it means to play but waits
    /// for data. Polled every second while it lasts.
    func noteBuffering(_ waiting: Bool) {
        guard waiting != isBuffering else { return }
        isBuffering = waiting
        evaluateStall()
        stallPoll?.cancel()
        guard waiting else { return }
        stallPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.isBuffering else { return }
                self.evaluateStall()
            }
        }
    }

    /// A seek, a pause, a new item: waits right after one are expected.
    func noteInterruption() {
        stallMonitor.restartGrace(at: .now)
    }

    /// The player showed a frame of the stream.
    func notePresented() {
        hasPresentedVideo = true
        startupWatch?.cancel()
    }

    private func evaluateStall() {
        guard adapts, stallMonitor.update(waiting: isBuffering, at: .now) else { return }
        stepDown(reason: "kept stalling")
    }

    /// Under Auto a stream that shows no frame within
    /// `StreamStallMonitor.startupTimeout` steps down.
    private func armStartupWatch() {
        startupWatch?.cancel()
        startupWatch = Task { [weak self] in
            try? await Task.sleep(for: .seconds(StreamStallMonitor.startupTimeout))
            guard !Task.isCancelled, let self, self.adapts, !self.hasPresentedVideo else { return }
            self.stepDown(reason: "didn't start")
        }
    }

    private func stepDown(reason: String) {
        guard let next = LibraryStreamQuality.stepDown(from: level, sourceBitrate: sourceBitrate) else {
            stallMonitor.noteStepped(at: .now)
            AppLogger.videoWindow.info("[tvOS] Stream \(reason, privacy: .public) at the lowest quality; nothing lower to try")
            showNotice("Still buffering at the lowest quality")
            return
        }
        AppLogger.videoWindow.info("[tvOS] Auto quality: stream \(reason, privacy: .public) at \(self.level?.rawValue ?? "original", privacy: .public); stepping down to \(next.rawValue, privacy: .public)")
        switchStream(to: next, reason: "auto", notice: "Quality lowered to \(next.title) to keep playing")
    }

    // MARK: - Notice

    private func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private func dismissNotice() {
        noticeTask?.cancel()
        notice = nil
    }

    func stop() {
        stallPoll?.cancel()
        startupWatch?.cancel()
        switchTask?.cancel()
        noticeTask?.cancel()
        #if HYPNOS_YOUTUBE
        youTubeTask?.cancel()
        #endif
    }

    // MARK: - YouTube

    #if HYPNOS_YOUTUBE
    let isYouTube: Bool
    private(set) var youTubeRenditions: [YouTubeRendition] = []
    /// The rendition chosen (its size class); nil is Auto.
    private(set) var youTubeChosenHeight: Int? = YouTubeQuality.preferred.height
    /// The master playing: YouTube's own, or one with its 5.1 spliced in.
    @ObservationIgnored private var youTubeMaster: (url: URL, text: String)?
    /// YouTube's own master, where a failed surround swap goes back to.
    @ObservationIgnored private var youTubeStereoMaster: (url: URL, text: String)?
    @ObservationIgnored private var youTubeTask: Task<Void, Never>?

    /// YouTube's own master (never a loopback copy): what surround is found for.
    var youTubeStereoMasterURL: URL? { youTubeStereoMaster?.url }

    /// Reads `master`'s renditions and returns what to play from it: a copy
    /// holding only the chosen size, or the master itself under Auto (and
    /// for a stream that isn't a master).
    func adoptYouTubeMaster(_ master: URL, isSurround: Bool = false) async -> URL {
        guard let text = await YouTubeRenditions.playlistText(at: master) else { return master }
        let renditions = YouTubeRenditions.parse(master: text)
        guard !renditions.isEmpty else { return master }
        youTubeMaster = (master, text)
        if !isSurround { youTubeStereoMaster = (master, text) }
        youTubeRenditions = renditions
        if let chosen = youTubeChosenHeight {
            // The highest the video has at or below the choice, else its lowest.
            youTubeChosenHeight = renditions.first { $0.height <= chosen }?.height ?? renditions.last?.height
        }
        AppLogger.youtube.info("[tvOS] Renditions: \(renditions.map(\.title).joined(separator: ", "), privacy: .public); playing \(self.youTubeChosenHeight.map { "\($0)p" } ?? "Auto", privacy: .public)")
        return await youTubeStream(from: (master, text))
    }

    /// Back on YouTube's own master after the surround one failed.
    func youTubeStereoFallback() async -> URL? {
        guard let stereo = youTubeStereoMaster else { return nil }
        youTubeMaster = stereo
        return await youTubeStream(from: stereo)
    }

    /// The chosen size's copy of `master`, or `master` itself under Auto.
    private func youTubeStream(from master: (url: URL, text: String)) async -> URL {
        guard let height = youTubeChosenHeight else { return master.url }
        if let copy = await YouTubeRenditions.publish(master.text, from: master.url, keepingHeight: height) {
            return copy
        }
        AppLogger.youtube.error("[tvOS] Couldn't serve the \(height, privacy: .public)p rendition; playing the whole master")
        return master.url
    }

    /// What the menu's title says is playing ("1080p", "Auto").
    var youTubeLabel: String {
        youTubeChosenHeight.map(YouTubeRendition.badge) ?? "Auto"
    }

    /// The viewer picked a rendition (nil: Auto): saved for every YouTube
    /// video, and swapped in at the playhead.
    func chooseYouTube(height: Int?) {
        guard height != youTubeChosenHeight else { return }
        YouTubeQuality.preferred = height.map(YouTubeQuality.level(height:)) ?? .auto
        youTubeChosenHeight = height
        AppLogger.youtube.info("[tvOS] Quality set to \(height.map { "\($0)p" } ?? "Auto", privacy: .public)")
        guard let master = youTubeMaster else { return }
        youTubeTask?.cancel()
        youTubeTask = Task { [weak self] in
            guard let self else { return }
            let url = await self.youTubeStream(from: master)
            guard !Task.isCancelled, url != self.streamURL else { return }
            self.onSwitch(url)
        }
    }

    /// A chosen size's HDR copy the player refused: SDR from now on this OS,
    /// and the same size again without HDR. Nil when that wasn't the problem.
    func youTubeDropHDR() async -> URL? {
        guard let master = youTubeMaster, youTubeChosenHeight != nil,
              YouTubeRenditions.offersHDR(master.text) else { return nil }
        AppLogger.youtube.info("[tvOS] The HDR rendition failed; playing SDR instead")
        YouTubeRenditions.noteHDRRefused()
        youTubeRenditions = YouTubeRenditions.parse(master: master.text, preferringHDR: false)
        return await youTubeStream(from: master)
    }
    #endif
}

#endif
