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
    /// Side length of the square cell. The grid shrinks this below the
    /// default to keep a minimum column count when the window is narrow.
    var size: CGFloat = 200
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
    /// grid. 800 keeps the square crop's short edge covering a 200pt cell at
    /// 2x for sources up to 2:1.
    static let thumbnailMaxSize: CGFloat = 800
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
                Image(platformImage: dioramaPair.backdrop)
                    .resizable()
                    .scaledToFill()
                Image(platformImage: dioramaPair.foreground)
                    .resizable()
                    .scaledToFill()
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
        .frame(width: size, height: size)
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
                loadedImage = Self.cropToSquare(result.image)
            } else {
                AppLogger.views.warning("Failed to load thumbnail for: \(image.thumbnailURL.lastPathComponent, privacy: .private)")
                loadFailed = true
            }
        } else {
            // Remote URLs: use cached thumbnail path (stores cropped result in ThumbnailCache)
            if let result = await ImageLoader.shared.loadRemoteThumbnailCached(from: image.thumbnailURL, maxSize: Self.thumbnailMaxSize, crop: Self.cropToSquare) {
                loadedImage = result
            } else {
                AppLogger.views.warning("Failed to load thumbnail for: \(image.thumbnailURL.lastPathComponent, privacy: .private)")
                loadFailed = true
            }
        }
        isLoading = false
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

    private nonisolated static func cropToSquare(_ image: UIImage) -> UIImage {
        let side = min(image.size.width, image.size.height)
        let xOffset = (image.size.width - side) / 2
        let yOffset = (image.size.height - side) / 2
        
        let cropRect = CGRect(x: xOffset, y: yOffset, width: side, height: side)
        
        guard let cgImage = image.cgImage?.cropping(to: cropRect) else {
            return image
        }
        
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }
}

struct CellFramePreferenceKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
