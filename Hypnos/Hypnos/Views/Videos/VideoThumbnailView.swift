/*
 Hypnos - Video Thumbnail View

 Individual video thumbnail with duration overlay.
 */

import DebugTrace
import SwiftUI

struct VideoThumbnailView: View {
    /// Max thumbnail dimension for the grid. 16:9 → ~384×216 — crisp at the
    /// cell sizes a large (dense) window produces while keeping decoded bitmaps
    /// small so 60+ thumbnails don't thrash memory/compositing bandwidth.
    static let thumbnailMaxSize: CGFloat = 384

    @Environment(AppModel.self) private var appModel
    let video: GalleryVideo
    /// Fires on tap, after the debounce guard and press-flash animation.
    /// Mirrors `GalleryThumbnailView.onTap`. `nil` in selection mode, where
    /// the grid attaches its own external tap gesture instead.
    var onTap: (() -> Void)? = nil
    /// Fires when the cell's long-press grow-and-pop gesture completes.
    /// Receives the cell's already-loaded thumbnail bitmap (if any) so the
    /// quick look preview can use it as an instant poster seed while the
    /// preview clip buffers. Mirrors `GalleryThumbnailView.onLongPress`.
    var onLongPress: ((UIImage?) -> Void)? = nil
    /// Hides the cell while its quick look preview is up.
    var quickLookActive: Bool = false
    /// Coordinate space name used by the gallery grid to publish the cell's
    /// frame via `CellFramePreferenceKey` for the scale-from-cell transition.
    var cellCoordinateSpace: String? = nil
    @State private var loadedImage: UIImage?
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var pressPhase: PressPhase = .idle
    @State private var growthTask: Task<Void, Never>?

    private enum PressPhase: Equatable {
        case idle
        /// Initial press-down ("button press" feedback).
        case pressed
        /// Slow grow toward a slightly-larger-than-natural size that
        /// telegraphs the impending quick look pop.
        case anticipating
    }

    private var pressScale: CGFloat {
        switch pressPhase {
        case .idle: return 1.0
        case .pressed: return 0.92
        case .anticipating: return 1.08
        }
    }

    private var displayName: String {
        if let title = video.title, !title.isEmpty {
            return title
        }
        if let fileName = video.fileName, !fileName.isEmpty {
            return fileName
        }
        return video.thumbnailURL.deletingPathExtension().lastPathComponent
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                // Background
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))

                // Thumbnail image
                if let loadedImage {
                    Image(platformImage: loadedImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    // Static placeholder for both the loading and failed states.
                    // A ProgressView (UIKit activity indicator) can't be
                    // rasterized inside .drawingGroup() and renders as a broken
                    // glyph; on a fast (LAN) source the load is near-instant, so
                    // a still icon is enough.
                    Image(systemName: "video")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                }

                // Play button overlay. No drop shadow — a per-cell shadow forces
                // an offscreen blur pass, which is a meaningful cost across a
                // gridful of cells. The fill-color SF Symbol already reads on
                // most thumbnails.
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Bottom badges (3D indicator and duration)
                HStack(spacing: 6) {
                    // 3D badge for stereoscopic videos
                    if video.isStereoscopic {
                        HStack(spacing: 2) {
                            if let format = video.stereoscopicFormat {
                                Text(format.shortLabel)
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                            } else {
                                Text("3D")
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                            }
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.8))
                        .foregroundColor(.white)
                        .cornerRadius(4)
                    }

                    Spacer()

                    // Duration badge
                    if let duration = video.formattedDuration {
                        Text(duration)
                            .font(.caption)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.7))
                            .foregroundColor(.white)
                            .cornerRadius(4)
                    }
                }
                .padding(8)
            }
            .aspectRatio(16/9, contentMode: .fit)

            // Filename bar
            Text(displayName)
                .font(.caption)
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.black)
        }
        .cornerRadius(12)
        .clipped()
        // Flatten the cell (background + image + play button + badges +
        // filename bar) into a single Metal-rendered texture. The column-count
        // realignment animation then just moves/scales one texture per cell
        // instead of recompositing ~6 layers every frame. Re-rasterizes when
        // the thumbnail finishes loading; the trade-off is the loading spinner
        // no longer animates, which is fine on a fast (LAN) source.
        .drawingGroup()
        .contentShape(Rectangle())
        .hoverEffect(ScaleHoverEffect())
        .scaleEffect(pressScale)
        .opacity(quickLookActive ? 0 : 1)
        // The cell-hide / cell-show flip happens in the same render commit as
        // the quick look preview's appear/disappear. Any inherited animation
        // context would smear the opacity change across a settling spring.
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
                    withAnimation(.easeOut(duration: 0.08)) {
                        pressPhase = .pressed
                    }
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
            await loadThumbnail()
        }
        .onDisappear {
            loadedImage = nil
            isLoading = true
            loadFailed = false
        }
    }

    @ViewBuilder
    private var cellFrameProbe: some View {
        if let space = cellCoordinateSpace {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: CellFramePreferenceKey.self,
                    value: [video.id: proxy.frame(in: .named(space))]
                )
            }
        } else {
            Color.clear
        }
    }

    private func loadThumbnail() async {
        if video.thumbnailURL.isFileURL {
            // Local files: use efficient downsampling path
            if let image = await ImageLoader.shared.loadThumbnail(from: video.thumbnailURL) {
                loadedImage = await displayReady(Self.cropTo16x9(image))
            } else {
                AppLogger.views.warning("Failed to load video thumbnail: \(video.thumbnailURL.lastPathComponent, privacy: .private)")
                loadFailed = true
            }
        } else {
            // Remote URLs: downsample + cache (stores cropped result in ThumbnailCache)
            if let image = await ImageLoader.shared.loadRemoteThumbnailCached(from: video.thumbnailURL, maxSize: Self.thumbnailMaxSize, crop: Self.cropTo16x9) {
                loadedImage = await displayReady(image)
            } else {
                AppLogger.views.warning("Failed to load video thumbnail: \(video.thumbnailURL.lastPathComponent, privacy: .private)")
                loadFailed = true
            }
        }
        isLoading = false
    }

    /// Decode into a display-ready bitmap once, off the main thread, so
    /// compositing/scrolling doesn't re-decode the (possibly non-display-format)
    /// CGImageSource thumbnail every frame. Falls back to the original on
    /// failure. The square image grid gets this for free via its redraw path.
    private func displayReady(_ image: UIImage) async -> UIImage {
        await image.byPreparingForDisplay() ?? image
    }
    
    nonisolated static func cropTo16x9(_ image: UIImage) -> UIImage {
        let targetAspect: CGFloat = 16.0 / 9.0
        let imageAspect = image.size.width / image.size.height
        
        var cropRect: CGRect
        
        if imageAspect > targetAspect {
            // Image is wider than 16:9, crop width
            let targetWidth = image.size.height * targetAspect
            let xOffset = (image.size.width - targetWidth) / 2
            cropRect = CGRect(x: xOffset, y: 0, width: targetWidth, height: image.size.height)
        } else {
            // Image is taller than 16:9, crop height
            let targetHeight = image.size.width / targetAspect
            let yOffset = (image.size.height - targetHeight) / 2
            cropRect = CGRect(x: 0, y: yOffset, width: image.size.width, height: targetHeight)
        }
        
        guard let cgImage = image.cgImage?.cropping(to: cropRect) else {
            return image
        }
        
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }
}
