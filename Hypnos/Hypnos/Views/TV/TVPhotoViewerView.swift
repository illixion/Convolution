/*
 Hypnos - tvOS fullscreen photo viewer

 Siri Remote replaces the visionOS/iOS viewer's swipe and ornament: left/
 right (`.onMoveCommand`) move to the previous/next image, and Play/Pause
 (`.onPlayPauseCommand`) starts or stops a slideshow over the same list.
 There is no adjustments popover, no 3D mode, no share sheet — none of
 `PhotoDisplayView`'s machinery is reused, deliberately (see
 `Hypnos/CLAUDE.md` "tvOS"): this is a plain full-resolution image behind
 the Menu button, which `fullScreenCover` wires up for free.
 */

#if os(tvOS)

import SwiftUI

struct TVPhotoViewerView: View {
    let images: [GalleryImage]
    let startIndex: Int
    /// Requests the next page from the caller's source when navigation gets
    /// near the end of what's loaded so far — same trigger the grid uses.
    var onLoadMore: () async -> Void = {}

    @State private var index: Int
    @State private var currentImage: UIImage?
    @State private var isLoading = false
    @State private var isSlideshow = false
    @State private var slideshowTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    init(images: [GalleryImage], startIndex: Int, onLoadMore: @escaping () async -> Void = {}) {
        self.images = images
        self.startIndex = startIndex
        self.onLoadMore = onLoadMore
        _index = State(initialValue: startIndex)
    }

    private var image: GalleryImage? { images[safe: index] }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let currentImage {
                Image(platformImage: currentImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    // tvOS insets the safe area for TV overscan; without this the
                    // picture is letterboxed on all four sides.
                    .ignoresSafeArea()
            } else if isLoading {
                ProgressView()
            }

            VStack {
                Spacer()
                if isSlideshow {
                    Label("Slideshow", systemImage: "play.fill")
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 40)
                }
            }
        }
        .onMoveCommand { direction in
            switch direction {
            case .left: step(by: -1)
            case .right: step(by: 1)
            default: break
            }
        }
        .onPlayPauseCommand {
            isSlideshow.toggle()
        }
        .onExitCommand { dismiss() }
        .onChange(of: isSlideshow) { _, playing in
            playing ? startSlideshow() : stopSlideshow()
        }
        .task(id: index) {
            await load()
        }
        .onDisappear {
            stopSlideshow()
        }
    }

    private func step(by delta: Int) {
        let next = index + delta
        guard next >= 0, next < images.count else { return }
        index = next
        if index >= images.count - 3 {
            Task { await onLoadMore() }
        }
    }

    private func load() async {
        guard let image else { return }
        isLoading = true
        currentImage = try? await ImageLoader.shared.loadImage(from: image.fullSizeURL)
        isLoading = false
    }

    private func startSlideshow() {
        slideshowTask?.cancel()
        slideshowTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                if index + 1 < images.count {
                    step(by: 1)
                } else {
                    await onLoadMore()
                    if index + 1 < images.count {
                        step(by: 1)
                    } else {
                        isSlideshow = false
                    }
                }
            }
        }
    }

    private func stopSlideshow() {
        slideshowTask?.cancel()
        slideshowTask = nil
    }
}

#endif
