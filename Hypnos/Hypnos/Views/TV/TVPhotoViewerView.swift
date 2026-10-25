/*
 Hypnos - tvOS fullscreen photo viewer

 Siri Remote replaces the visionOS/iOS viewer's swipe and ornament: left/
 right (`.onMoveCommand`) move to the previous/next image, and Play/Pause
 (`.onPlayPauseCommand`) starts the app's slideshow (`onSlideshow`: the
 presenter closes the viewer and starts it over what the viewer was opened
 from, see `TVSlideshowView`).
 There is no adjustments popover, no 3D mode, no share sheet — none of
 `PhotoDisplayView`'s machinery is reused, deliberately (see
 `Hypnos/CLAUDE.md` "tvOS"): this is a plain full-resolution image behind
 the Menu button, which `fullScreenCover` wires up for free.

 `.onMoveCommand` can't tell a swipe on the touch surface from a press on
 the clickpad's edge (or an arrow on any other remote), and the two read in
 opposite directions: a swipe drags the photo (left brings the next one in,
 as in Photos), a press points at where to go (right is next).
 `TVArrowPressObserver` sees presses first, so the move command knows which
 it was.

 An animated GIF, APNG, WebP or HEIF sequence plays (`TVAnimatedImageView`,
 ImageIO's own frame timing) where the other platforms use WebKit, which
 tvOS lacks; its first frame is decoded like any picture and shows meanwhile.
 */

#if os(tvOS)

import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

struct TVPhotoViewerView: View {
    let images: [GalleryImage]
    let startIndex: Int
    /// Requests the next page from the caller's source when navigation gets
    /// near the end of what's loaded so far — same trigger the grid uses.
    var onLoadMore: () async -> Void = {}
    /// Play/Pause: the presenter's slideshow of what this viewer walks.
    var onSlideshow: (() -> Void)?

    @State private var index: Int
    @State private var currentImage: UIImage?
    /// The picture's encoded bytes while it is an animation; nil for a still.
    @State private var animatedData: Data?
    /// Index `currentImage` belongs to; keys the image's identity so a change
    /// animates as a transition instead of swapping in place.
    @State private var shownIndex: Int
    /// Edge the next photo slides in from. Set when the user steps, before the
    /// photo loads, so the outgoing one already leaves the matching way.
    @State private var slideEdge: Edge = .trailing
    @State private var isLoading = false
    @FocusState private var hasFocus: Bool
    @State private var arrowPresses = TVArrowPressObserver()
    @Environment(\.dismiss) private var dismiss

    init(images: [GalleryImage], startIndex: Int, onLoadMore: @escaping () async -> Void = {},
         onSlideshow: (() -> Void)? = nil) {
        self.images = images
        self.startIndex = startIndex
        self.onLoadMore = onLoadMore
        self.onSlideshow = onSlideshow
        _index = State(initialValue: startIndex)
        _shownIndex = State(initialValue: startIndex)
    }

    private static let maxDisplayPixels: CGFloat = 3840

    private var image: GalleryImage? { images[safe: index] }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let currentImage {
                Group {
                    if let animatedData {
                        TVAnimatedImageView(data: animatedData, poster: currentImage)
                    } else {
                        Image(platformImage: currentImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                }
                // tvOS insets the safe area for TV overscan; without this the
                // picture is letterboxed on all four sides. The frame first,
                // so the fit is made against the whole screen.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .id(shownIndex)
                .transition(.asymmetric(
                    insertion: .move(edge: slideEdge).combined(with: .opacity),
                    removal: .move(edge: slideEdge == .trailing ? .leading : .trailing)
                        .combined(with: .opacity)))
            } else if isLoading {
                ProgressView()
            }
        }
        // Remote events (swipes, clickpad edges, Play/Pause) only reach a
        // focused view, and a bare ZStack never takes focus.
        .background(TVArrowPressObserver.Host(observer: arrowPresses))
        .focusable()
        .focused($hasFocus)
        .onAppear { hasFocus = true }
        .onMoveCommand { direction in
            // A press points where to go; a swipe drags the photo, so a left
            // swipe brings the next one in, as in the Photos app.
            let forward: Int = arrowPresses.justPressed() ? 1 : -1
            switch direction {
            case .right: step(by: forward)
            case .left: step(by: -forward)
            default: break
            }
        }
        .onPlayPauseCommand {
            onSlideshow?()
        }
        .onExitCommand { dismiss() }
        .task(id: index) {
            await load()
        }
    }

    private func step(by delta: Int) {
        let next = index + delta
        guard next >= 0, next < images.count else { return }
        slideEdge = delta > 0 ? .trailing : .leading
        index = next
        if index >= images.count - 3 {
            Task { await onLoadMore() }
        }
    }

    private func load() async {
        guard let image else { return }
        isLoading = true
        // Cancelled when the user steps on (`.task(id: index)`), which also
        // stops the download and skips the decode of a photo already left behind.
        // 4K is the most a TV can show, so nothing above that is ever decoded.
        let data = try? await ImageLoader.shared.loadRawData(from: image.fullSizeURL)
        guard !Task.isCancelled else { return }
        var decoded: (still: UIImage?, animated: Data?)?
        if let data {
            let maxPixels = Self.maxDisplayPixels
            decoded = await Task.detached(priority: .userInitiated) {
                (MetalImageRenderer.downsampledImage(from: data, maxDimension: maxPixels),
                 TVAnimatedImage.isAnimated(data) ? data : nil)
            }.value
        }
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            currentImage = decoded?.still
            animatedData = decoded?.animated
            shownIndex = index
        }
        isLoading = false
    }

}

/// Notes the remote's left/right arrow presses (clickpad edges, D-pads,
/// keyboards) without ever handling one: it fails on sight and cancels
/// nothing, so the press still reaches the focused view as a move command.
/// Gesture recognizers get each press before the view does, and swipes on
/// the touch surface aren't presses, so a move command arriving just after
/// one of these was a press.
final class TVArrowPressObserver: UIGestureRecognizer {
    private var lastPress: TimeInterval = -.infinity

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        allowedTouchTypes = []
        allowedPressTypes = [UIPress.PressType.leftArrow, .rightArrow].map { NSNumber(value: $0.rawValue) }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        if presses.contains(where: { $0.type == .leftArrow || $0.type == .rightArrow }) {
            lastPress = ProcessInfo.processInfo.systemUptime
        }
        state = .failed
    }

    /// Whether the move command being handled came from a press.
    func justPressed() -> Bool {
        ProcessInfo.processInfo.systemUptime - lastPress < 0.5
    }

    /// Attaches the observer to the window while the viewer is on screen:
    /// presses travel up from the focused view, and the window is above it.
    struct Host: UIViewRepresentable {
        let observer: TVArrowPressObserver

        func makeUIView(context: Context) -> HostView { HostView(observer: observer) }
        func updateUIView(_ view: HostView, context: Context) {}
        static func dismantleUIView(_ view: HostView, coordinator: ()) { view.detach() }
    }

    final class HostView: UIView {
        let observer: TVArrowPressObserver

        init(observer: TVArrowPressObserver) {
            self.observer = observer
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            window?.addGestureRecognizer(observer)
        }

        func detach() {
            observer.view?.removeGestureRecognizer(observer)
        }
    }
}

#endif
