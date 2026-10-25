/*
 Hypnos - Mac viewer windows

 A picture, video or slideshow window on the Mac is the visionOS viewer in a
 window of its own: dark whatever the system appearance, the picture to the
 window's edges under a hidden title bar (the traffic lights float over it),
 named after what it shows for the Window menu and Mission Control.

 The keys are the window's own rather than menu shortcuts, which would also
 take what is typed into a text field (an Info sheet's): space plays and
 pauses a video, the arrows step it 10 s or go to the previous or next
 picture. The menu bar's Playback items reach the key video window through
 its focused scene value.

 The window takes the shape of what it shows, as a visionOS viewer does:
 each new picture or video keeps the window's width (less, if the height
 would leave the screen) and fixes its aspect for resizing.
 */

#if os(macOS)
import SwiftUI

extension View {
    func viewerWindowChrome() -> some View {
        background(Color.black.ignoresSafeArea())
            .ignoresSafeArea(.container, edges: .top)
            .preferredColorScheme(.dark)
    }

    func macVideoWindow(_ windowModel: VideoWindowModel) -> some View {
        modifier(MacViewerKeys(title: windowModel.videoDisplayName, aspect: windowModel.videoAspectRatio) { key in
            switch key {
            case .space: windowModel.togglePlayPause()
            case .leftArrow: windowModel.seek(by: -10)
            case .rightArrow: windowModel.seek(by: 10)
            default: return false
            }
            return true
        })
        .focusedSceneValue(\.videoWindowModel, windowModel)
    }

    func macPhotoWindow(_ windowModel: PhotoWindowModel) -> some View {
        modifier(MacViewerKeys(title: [windowModel.image.title, windowModel.image.fileName].compactMap { $0 }
                                   .first { !$0.isEmpty } ?? "Picture",
                               aspect: windowModel.imageAspectRatio) { key in
            switch key {
            case .leftArrow: Task { await windowModel.previousGalleryImage() }
            case .rightArrow: Task { await windowModel.nextGalleryImage() }
            default: return false
            }
            return true
        })
    }
}

/// A restored window whose value no longer decodes (one an older build
/// saved): it closes rather than staying blank.
struct UnrestorableWindow: View {
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear.onAppear { dismissWindow() }
    }
}

/// The window's title, shape and keys (while nothing in it takes them first).
private struct MacViewerKeys: ViewModifier {
    let title: String
    let aspect: CGFloat?
    let handle: (KeyEquivalent) -> Bool
    @FocusState private var focused: Bool
    @State private var host = MacWindowReference()

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .background(MacWindowReader(reference: host))
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onAppear { focused = true }
            .onKeyPress(keys: [.space, .leftArrow, .rightArrow]) { press in
                handle(press.key) ? .handled : .ignored
            }
            .onChange(of: aspect, initial: true) { _, aspect in
                if let aspect { host.fit(aspect: aspect) }
            }
            .onChange(of: host.window != nil) { _, attached in
                if attached, let aspect { host.fit(aspect: aspect) }
            }
    }
}

/// The `NSWindow` a view is in, once it is.
@MainActor
@Observable
final class MacWindowReference {
    @ObservationIgnored weak var nsWindow: NSWindow? {
        didSet { window = nsWindow.map(ObjectIdentifier.init) }
    }
    /// Observable stand-in for `nsWindow`, which a weak reference can't be.
    private(set) var window: ObjectIdentifier?
    @ObservationIgnored private var fitted: CGFloat?

    /// The window's content at `aspect` (width over height): its width kept,
    /// or narrowed so the height fits the screen. Resizing keeps the aspect.
    /// Not in full screen, and once per shape.
    func fit(aspect: CGFloat) {
        guard let nsWindow, aspect.isFinite, aspect > 0, aspect != fitted,
              !nsWindow.styleMask.contains(.fullScreen) else { return }
        fitted = aspect
        nsWindow.contentAspectRatio = NSSize(width: aspect, height: 1)
        let content = nsWindow.contentRect(forFrameRect: nsWindow.frame)
        let available = nsWindow.screen?.visibleFrame.size ?? content.size
        let chrome = nsWindow.frame.height - content.height
        var size = NSSize(width: content.width, height: content.width / aspect)
        if size.height > available.height - chrome {
            size.height = available.height - chrome
            size.width = size.height * aspect
        }
        var frame = nsWindow.frameRect(forContentRect: NSRect(origin: content.origin, size: size))
        // Grow or shrink from the top edge, where the title bar is.
        frame.origin.y = nsWindow.frame.maxY - frame.height
        nsWindow.setFrame(frame, display: true, animate: true)
    }
}

/// Hands its window to `reference`.
private struct MacWindowReader: NSViewRepresentable {
    let reference: MacWindowReference

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.reference = reference
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        weak var reference: MacWindowReference?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reference?.nsWindow = window
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
