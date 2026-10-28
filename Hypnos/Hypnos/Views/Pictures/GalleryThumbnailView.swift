/*
 Hypnos - Gallery Thumbnail View

 Individual thumbnail view with async image loading, animated GIF support,
 and visionOS hover effects.
 */

import DebugTrace
import DebugTraceUI
import RAVEMedia
import SwiftUI

struct GalleryThumbnailView: View {
    @Environment(AppModel.self) private var appModel
    @PatchRefresh var patchRefresh
    let image: GalleryImage
    /// Cell size. Square in the square grid; in the original-aspect grid the
    /// width follows the image's ratio at the row's height. The bitmap is
    /// never cropped in advance — `scaledToFill` center-crops it to whatever
    /// the cell is, so one cached thumbnail (and one diorama) serves both.
    var size: CGSize = CGSize(width: 200, height: 200)
    var onTap: (() -> Void)? = nil
    /// Runs the context menu's Quick Look item. Receives the cell's
    /// already-loaded thumbnail bitmap (if available) so the Quick Look
    /// preview can use it as a seed — without that, QL's first paint is
    /// empty until its own async thumbnail load lands, which the user sees
    /// as a gray loading frame or a weirdly-cropped image mid-animation.
    var onQuickLook: ((UIImage?) -> Void)? = nil
    /// The long-press (right-click) menu. Handed a Quick Look action bound to
    /// this cell's loaded thumbnail, for the grid to place among its items.
    var contextMenuItems: ((_ quickLook: @escaping () -> Void) -> AnyView)? = nil
    var quickLookActive: Bool = false
    /// Coordinate space name used by the gallery grid to publish the
    /// cell's frame via `CellFramePreferenceKey`. The Quick Look
    /// overlay reads that frame to drive its scale-from-cell transition.
    var cellCoordinateSpace: String? = nil
    /// Long-edge cap for remote thumbnails, which are also the diorama's
    /// source. A server can answer the thumbnail URL with the full original;
    /// uncapped, that bitmap and its two diorama layers are what stalled the
    /// grid. 1000 covers the widest original-aspect cell (2.5:1 at a 200pt row,
    /// 2x) and a square cell's short edge with room to spare.
    static let thumbnailMaxSize: CGFloat = 1000
    /// How long a cell must stay on screen before it starts a network fetch.
    /// A fast flick realizes and discards cells faster than this, so nothing
    /// is downloaded for content that only flashed past. Warm caches skip it.
    private static let coldLoadDelay: Duration = .milliseconds(120)
    @State private var loadedImage: UIImage?
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var dioramaPair: ThumbnailDioramaCache.Pair?
    @State private var depth: ThumbnailDioramaCache.ThumbnailDepth?
    /// Settle time before a cell asks for depth. The estimator also drops
    /// cancelled requests unrun, so this is only the first filter.
    private static let depthRequestDelay: Duration = .milliseconds(250)

    var body: some View {
        ZStack {
            // Background. Not behind a 3D tile: the tile's flat parts sit
            // near the window plane, and a fill there z-fights with them.
            if !showsTile {
                Color.secondary.opacity(0.2)
            }

            #if os(visionOS)
            if let depth, let loadedImage, appModel.effectiveThumbnailDepth {
                DepthTileView(image: loadedImage, depth: depth.map, size: size)
                tileInputTarget(lift: RAVEStereoPhotoView.inputTargetZ)
            } else if let dioramaPair, showsDiorama {
                DioramaTileView(backdrop: dioramaPair.backdrop, foreground: dioramaPair.foreground, size: size)
                tileInputTarget(lift: DioramaTileView.lift)
            } else if let loadedImage {
                Image(platformImage: loadedImage)
                    .resizable()
                    .scaledToFill()
            }
            #else
            if let loadedImage {
                Image(platformImage: loadedImage)
                    .resizable()
                    .scaledToFill()
            }
            #endif
            if loadedImage == nil, !showsTile, isLoading {
                ProgressView()
            } else if loadedImage == nil, !showsTile {
                // Error state
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    if loadFailed {
                        Text("Failed to load")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .cornerRadius(12)
        .clipped()
        .contentShape(Rectangle())
        .thumbnailHoverEffect(reduceMotion: appModel.effectiveReduceMotion)
        // Hidden under its Quick Look, except a 3D tile: the pop rests in
        // front of the tiles and fades out over the cell when it closes, so
        // the tile has to be there already to take over.
        .opacity(quickLookActive && !showsTile ? 0 : 1)
        // The cell-hide / cell-show flip happens in the same render
        // commit as Quick Look's appear/disappear. Any inherited
        // animation context (e.g. a still-settling dismiss spring)
        // would smear the opacity change across that spring's duration,
        // producing the "thumbnail flies in" glitch on dismiss.
        .animation(nil, value: quickLookActive)
        .background(cellFrameProbe)
        .thumbnailTap(reduceMotion: appModel.effectiveReduceMotion) {
            guard appModel.beginMediaOpenTap() else { return }
            onTap?()
        }
        .thumbnailMenu(reduceMotion: appModel.effectiveReduceMotion,
                       quickLook: onQuickLook.map { quickLook in { quickLook(loadedImage) } }) {
            if let contextMenuItems {
                contextMenuItems { onQuickLook?(loadedImage) }
            }
        }
        .task {
            // Load base thumbnail and any cached diorama in parallel so a
            // disk-warm pair lands in the same render commit as the base —
            // no foreground pop-in on scroll.
            async let baseTask: Void = loadThumbnail()
            async let cachedDioramaTask: ThumbnailDioramaCache.Pair? = preloadCachedDiorama()
            async let cachedDepthTask: ThumbnailDioramaCache.ThumbnailDepth? = preloadCachedDepth()
            _ = await baseTask
            let cachedDepth = await cachedDepthTask
            if let cachedDepth { depth = cachedDepth }
            let cachedPair = await cachedDioramaTask
            if usesDepth {
                // A pair left from the Diorama style shows until depth lands;
                // none is generated for this style (one model pass per cell).
                dioramaPair = cachedPair
                if cachedDepth == nil { await generateDepthIfPossible() }
            } else if let cachedPair {
                dioramaPair = cachedPair
            } else {
                await generateDioramaIfPossible()
            }
        }
        .onDisappear {
            loadedImage = nil
            isLoading = true
            loadFailed = false
            dioramaPair = nil
            depth = nil
        }
    }

    /// The cell's 3D tile is up, so nothing else may draw on its plane.
    private var showsTile: Bool {
        #if os(visionOS)
        (depth != nil && loadedImage != nil && appModel.effectiveThumbnailDepth) || (dioramaPair != nil && showsDiorama)
        #else
        false
        #endif
    }

    private var showsDiorama: Bool {
        appModel.effectiveThumbnailDiorama || appModel.effectiveThumbnailDepth
    }

    /// An input target in front of the stereo plane. RealityKit content can
    /// catch pointer and hand scrolling even with hit testing off, so a drawn
    /// SwiftUI layer ahead of it gets them first. Not `.clear`: a fully clear
    /// layer isn't targetable.
    private func tileInputTarget(lift: CGFloat) -> some View {
        Color.white.opacity(0.001)
            .offset(z: lift + 2)
    }

    /// `.depth` with a model to run it. Without one the style behaves as
    /// `.diorama`, so choosing it before installing a model isn't a dead end.
    private var usesDepth: Bool {
        appModel.effectiveThumbnailDepth && RAVEStillDepthEstimator.shared.isModelAvailable
    }

    private func preloadCachedDepth() async -> ThumbnailDioramaCache.ThumbnailDepth? {
        guard appModel.effectiveThumbnailDepth else { return nil }
        return await ThumbnailDioramaCache.shared.cachedOrDiskDepth(for: image.thumbnailURL)
    }

    private func generateDepthIfPossible() async {
        guard let loadedImage else { return }
        do { try await Task.sleep(for: Self.depthRequestDelay) } catch { return }
        let result = await ThumbnailDioramaCache.shared.depth(for: image.thumbnailURL) { loadedImage }
        guard !Task.isCancelled else { return }
        depth = result
    }

    /// Memory + disk lookup only — never invokes Vision. Returns `nil` if
    /// no cached pair exists, in which case the caller falls through to
    /// `generateDioramaIfPossible()` for cold generation.
    private func preloadCachedDiorama() async -> ThumbnailDioramaCache.Pair? {
        guard appModel.effectiveThumbnailDiorama || appModel.effectiveThumbnailDepth else { return nil }
        return await ThumbnailDioramaCache.shared.cachedOrDisk(for: image.thumbnailURL, maxPixelSize: Self.thumbnailMaxSize)
    }

    /// Cold-path generation: kicks off Vision-driven foreground/backdrop
    /// generation. A short debounce avoids queuing work for thumbnails
    /// that scroll past quickly.
    private func generateDioramaIfPossible() async {
        guard let loadedImage else { return }
        guard appModel.effectiveThumbnailDiorama || appModel.effectiveThumbnailDepth else { return }
        let key = image.thumbnailURL
        do {
            try await Task.sleep(nanoseconds: 400_000_000)
        } catch {
            return // cancelled (scrolled away)
        }
        let pair = await ThumbnailDioramaCache.shared.dioramaPair(for: key) { loadedImage }
        guard !Task.isCancelled else { return }
        dioramaPair = pair
    }

    private func loadThumbnail() async {
        if image.thumbnailURL.isFileURL {
            // Local files: use efficient downsampling path
            if let result = await ImageLoader.shared.loadThumbnailWithData(from: image.thumbnailURL) {
                show(result.image)
            } else if !Task.isCancelled {
                AppLogger.views.warning("Failed to load thumbnail for: \(image.thumbnailURL.lastPathComponent, privacy: .private)")
                loadFailed = true
            }
        } else if let warm = await ImageLoader.shared.cachedRemoteThumbnail(from: image.thumbnailURL, maxSize: Self.thumbnailMaxSize) {
            show(warm)
        } else {
            // Cold: wait out a flick before spending the network on this cell.
            // The sleep throws when the cell scrolls away and cancels the task.
            do { try await Task.sleep(for: Self.coldLoadDelay) } catch { return }
            if let result = await ImageLoader.shared.loadRemoteThumbnailCached(from: image.thumbnailURL, maxSize: Self.thumbnailMaxSize) {
                show(result)
            } else if !Task.isCancelled {
                AppLogger.views.warning("Failed to load thumbnail for: \(image.thumbnailURL.lastPathComponent, privacy: .private)")
                loadFailed = true
            }
        }
        // A cancelled load is a cell that scrolled away, not a failure; its
        // state is reset on disappear.
        guard !Task.isCancelled else { return }
        isLoading = false
    }

    /// Shows the bitmap and, when the source reported no dimensions, remembers
    /// its true ratio so the original-aspect grid lays this item out correctly
    /// from the first frame next time.
    private func show(_ bitmap: UIImage) {
        loadedImage = bitmap
        guard image.reportedAspectRatio == nil, bitmap.size.height > 0 else { return }
        MediaAspectStore.shared.record(ratio: bitmap.size.width / bitmap.size.height, for: image.identity)
    }

    /// Wraps the thumbnail's hover effect choice. Reduce-motion swaps the
    /// scale-up animation for the system default highlight so gaze still
    /// gives feedback without movement.
    @ViewBuilder
    private var cellFrameProbe: some View {
        if let space = cellCoordinateSpace {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: CellFramePreferenceKey.self,
                    value: [image.id: proxy.frame(in: .named(space))]
                )
            }
        } else {
            Color.clear
        }
    }
}

struct CellFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
