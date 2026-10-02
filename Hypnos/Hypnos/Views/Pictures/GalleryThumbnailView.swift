/*
 Hypnos - Gallery Thumbnail View

 Individual thumbnail view with async image loading, animated GIF support,
 and visionOS hover effects.
 */

import DebugTrace
import SwiftUI

struct GalleryThumbnailView: View {
    @Environment(AppModel.self) private var appModel
    let image: GalleryImage
    /// Cell size. Square in the square grid; in the original-aspect grid the
    /// width follows the image's ratio at the row's height. The bitmap is
    /// never cropped in advance — `scaledToFill` center-crops it to whatever
    /// the cell is, so one cached thumbnail (and one diorama) serves both.
    var size: CGSize = CGSize(width: 200, height: 200)
    var onTap: (() -> Void)? = nil
    /// Fires when the cell's long-press grows-and-pops gesture
    /// completes. Receives the cell's already-loaded thumbnail bitmap
    /// (if available) so the Quick Look preview can use it as a seed —
    /// without that, QL's first paint is empty until its own async
    /// thumbnail load lands, which the user sees as a gray loading
    /// frame or a weirdly-cropped image mid-animation.
    var onLongPress: ((UIImage?) -> Void)? = nil
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
    @State private var pressPhase: PressPhase = .idle
    @State private var growthTask: Task<Void, Never>?

    private enum PressPhase: Equatable {
        case idle
        /// Initial press-down ("button press" feedback).
        case pressed
        /// Slow grow toward a slightly-larger-than-natural size that
        /// telegraphs the impending Quick Look pop.
        case anticipating
    }

    private var pressScale: CGFloat {
        switch pressPhase {
        case .idle: return 1.0
        case .pressed: return 0.92
        case .anticipating: return 1.08
        }
    }

    var body: some View {
        ZStack {
            // Background
            Color.secondary.opacity(0.2)

            if let dioramaPair, appModel.effectiveThumbnailDiorama {
                // Two-layer diorama: blurred-subject backdrop, masked foreground
                // popped forward in z for an Apple TV-style parallax pop.
                // Each layer is clipped to the cell *before* the lift: the pair
                // is uncropped, so scaledToFill overflows a cell narrower than
                // the image, and a clip applied only to the stack would cut the
                // lifted layer in a different plane than the backdrop — the two
                // then project apart off-axis and during the hover scale.
                Image(platformImage: dioramaPair.backdrop)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
                Image(platformImage: dioramaPair.foreground)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .offset(z: 24)
            } else if let loadedImage {
                Image(platformImage: loadedImage)
                    .resizable()
                    .scaledToFill()
            } else if isLoading {
                ProgressView()
            } else {
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
        .modifier(ThumbnailHoverModifier(reduceMotion: appModel.effectiveReduceMotion))
        .scaleEffect(pressScale)
        .opacity(quickLookActive ? 0 : 1)
        // The cell-hide / cell-show flip happens in the same render
        // commit as Quick Look's appear/disappear. Any inherited
        // animation context (e.g. a still-settling dismiss spring)
        // would smear the opacity change across that spring's duration,
        // producing the "thumbnail flies in" glitch on dismiss.
        .animation(nil, value: quickLookActive)
        .background(cellFrameProbe)
        .onTapGesture {
            guard appModel.beginMediaOpenTap() else { return }
            if !appModel.effectiveReduceMotion {
                withAnimation(.easeOut(duration: 0.08)) { pressPhase = .pressed }
                withAnimation(.easeOut(duration: 0.15).delay(0.08)) { pressPhase = .idle }
            }
            onTap?()
        }
        .onLongPressGesture(
            minimumDuration: 0.65,
            perform: {
                growthTask?.cancel()
                onLongPress?(loadedImage)
                withAnimation(.easeOut(duration: 0.15)) { pressPhase = .idle }
            },
            onPressingChanged: { isPressing in
                growthTask?.cancel()
                if isPressing {
                    // Initial press-down: snap to a slightly smaller
                    // scale to give a button-press feedback.
                    withAnimation(.easeOut(duration: 0.08)) {
                        pressPhase = .pressed
                    }
                    // After a short delay, begin the slow anticipation
                    // grow — telegraphs the upcoming Quick Look pop.
                    growthTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeInOut(duration: 0.55)) {
                            pressPhase = .anticipating
                        }
                    }
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        pressPhase = .idle
                    }
                }
            }
        )
        .task {
            // Load base thumbnail and any cached diorama in parallel so a
            // disk-warm pair lands in the same render commit as the base —
            // no foreground pop-in on scroll.
            async let baseTask: Void = loadThumbnail()
            async let cachedDioramaTask: ThumbnailDioramaCache.Pair? = preloadCachedDiorama()
            _ = await baseTask
            if let pair = await cachedDioramaTask {
                dioramaPair = pair
            } else {
                await generateDioramaIfPossible()
            }
        }
        .onDisappear {
            loadedImage = nil
            isLoading = true
            loadFailed = false
            dioramaPair = nil
        }
    }

    /// Memory + disk lookup only — never invokes Vision. Returns `nil` if
    /// no cached pair exists, in which case the caller falls through to
    /// `generateDioramaIfPossible()` for cold generation.
    private func preloadCachedDiorama() async -> ThumbnailDioramaCache.Pair? {
        guard appModel.effectiveThumbnailDiorama else { return nil }
        return await ThumbnailDioramaCache.shared.cachedOrDisk(for: image.thumbnailURL, maxPixelSize: Self.thumbnailMaxSize)
    }

    /// Cold-path generation: kicks off Vision-driven foreground/backdrop
    /// generation. A short debounce avoids queuing work for thumbnails
    /// that scroll past quickly.
    private func generateDioramaIfPossible() async {
        guard let loadedImage else { return }
        guard appModel.effectiveThumbnailDiorama else { return }
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
    private struct ThumbnailHoverModifier: ViewModifier {
        let reduceMotion: Bool

        func body(content: Content) -> some View {
            #if os(macOS)
            content.hoverEffect(ScaleHoverEffect())
            #else
            if reduceMotion {
                content.hoverEffect(.highlight)
            } else {
                content.hoverEffect(ScaleHoverEffect())
            }
            #endif
        }
    }

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
