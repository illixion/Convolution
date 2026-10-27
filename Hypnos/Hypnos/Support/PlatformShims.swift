/*
 Hypnos - iOS/tvOS compatibility layer

 The app was written for visionOS first, and a handful of visionOS-only SwiftUI
 and RealityKit APIs are used from dozens of files: ornaments, glass backgrounds,
 z-offsets, `ImagePresentationComponent`, the spatial-audio policy. Rather than
 sprinkle `#if os(visionOS)` through every view, this file gives iOS a same-name
 stand-in for each of them with the closest flat-screen meaning:

 - `.ornament(...)`            → an overlay pinned to the matching edge, in a
                                 horizontal scroller when it is wider than the
                                 screen (a phone in portrait is narrower than
                                 any of the viewer bars).
 - `.glassBackgroundEffect()`  → iOS 26 Liquid Glass (`.glassEffect`).
 - `.offset(z:)`               → no-op; there is no depth axis.
 - `ImagePresentationComponent`→ a null-object RealityKit component: every
                                 query answers "mono / unsupported", and both
                                 `Spatial3DImage` initialisers throw. The photo
                                 model's 3D paths therefore compile unchanged
                                 and simply fail closed. The UI never offers
                                 them on iOS (see `PlatformCapabilities`).
 - `applySpatialAudioPolicy()` → no-op; head-tracked spatial audio is a
                                 visionOS window-placement concern.

 That `#if !os(visionOS)` section is compiled on **iOS and tvOS both** — tvOS
 inherits the iOS stand-ins wherever they still make sense (the null-object
 `ImagePresentationComponent`, the audio no-ops, `.offset(z:)`). Where tvOS
 needs something genuinely different — a real `.ornament` has no remote-driven
 equivalent, `.popover` doesn't exist at all — a further `#if os(tvOS)` /
 `#else` split appears inline, so the iOS behaviour above is unchanged.
 tvOS's *real* UI lives in `Views/TV/` and doesn't route through most of these
 shims at all (see Hypnos/CLAUDE.md "tvOS"); they exist so the rest of the
 shared module — which tvOS still compiles as one target — keeps building.

 `WindowGeometry` and `PlatformCapabilities` at the bottom are the things that
 exist on all three platforms: shared code calls them, and each platform
 supplies its own answer.
 */

import AVFoundation
import RealityKit
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Shared: what this build can do

/// Feature availability that shared code branches on at runtime, so a single
/// view can hide a control instead of the whole file being duplicated.
enum PlatformCapabilities {
    #if os(visionOS)
    /// RealityKit's `ImagePresentationComponent` 2D→3D conversion.
    static let supportsSpatial3D = true
    /// `ImmersiveSpace` scenes (immersive photo mode, MV-HEVC video).
    static let supportsImmersiveSpaces = true
    /// Several independent windows that can be summoned, hidden and saved as
    /// groups. iOS has one window per scene and no summon.
    static let supportsMultipleWindows = true
    /// The real-time fake-3D stereo pipeline (`Pseudo3DStereoEngine`), which
    /// renders a per-eye pair — meaningless on a flat display.
    static let supportsStereoVideo = true
    /// Diorama: background-removed foreground popped forward in z.
    static let supportsDiorama = true
    /// Whether the app may resize its own window (`requestGeometryUpdate`).
    static let supportsWindowResizing = true
    /// visionOS's own window handling: the Windows tab (summon, close,
    /// recycle), saved window groups, and viewers pushed in place of the
    /// gallery. A Mac has its Window menu and Mission Control instead, and
    /// opens every viewer in a window of its own.
    static let supportsWindowManagement = true
    #elseif os(macOS)
    static let supportsSpatial3D = false
    static let supportsImmersiveSpaces = false
    /// Every viewer opens in a window of its own, as on visionOS.
    static let supportsMultipleWindows = true
    static let supportsStereoVideo = false
    static let supportsDiorama = false
    static let supportsWindowResizing = false
    static let supportsWindowManagement = false
    #else
    static let supportsSpatial3D = false
    static let supportsImmersiveSpaces = false
    static let supportsMultipleWindows = false
    static let supportsStereoVideo = false
    static let supportsDiorama = false
    static let supportsWindowResizing = false
    static let supportsWindowManagement = false
    #endif

    /// Marketing name of the device family, for copy that names the platform.
    @MainActor
    static var deviceFamilyName: String {
        #if os(visionOS)
        return "Apple Vision Pro"
        #elseif os(tvOS)
        return "Apple TV"
        #elseif os(macOS)
        return "Mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }
}

// MARK: - Shared: window scene stand-in

#if os(macOS)
/// Stand-in for `UIWindowScene` — macOS has no scene delegate object at all (a
/// `Window`/`WindowGroup` scene maps straight to a real `NSWindow`), and this
/// app's window-*geometry-request* machinery is a no-op on macOS anyway, the
/// same as it already is on iOS and tvOS (see `PlatformCapabilities.
/// supportsWindowResizing`; ordinary AppKit window resizing covers macOS
/// instead). This type is never actually instantiated — it exists purely so
/// every `UIWindowScene`-shaped call site in the shared module (`SceneDelegate`,
/// `WindowGeometry`/`WindowResizeCoalescer`/`WindowSizeNudge`, the several
/// `resolvedWindowScene` properties) has a type to compile against.
final class PlatformWindowScene {
    var effectiveGeometrySize: CGSize { .zero }
}
#else
typealias PlatformWindowScene = UIWindowScene

extension UIWindowScene {
    /// Same value as `effectiveGeometry.coordinateSpace.bounds.size`, named to
    /// match `PlatformWindowScene.effectiveGeometrySize` so call sites read
    /// the same on every platform.
    var effectiveGeometrySize: CGSize {
        effectiveGeometry.coordinateSpace.bounds.size
    }
}
#endif

// MARK: - Shared: window geometry requests

/// The one place shared code asks the system to resize a window. visionOS
/// honours it through `UIWindowScene.GeometryPreferences.Vision`; iOS and
/// tvOS windows are sized by the system, so the request is dropped; macOS
/// windows are ordinary resizable AppKit windows, so it's dropped there too.
@MainActor
enum WindowGeometry {
    enum ResizingRestriction: Equatable {
        /// Keep the window's aspect ratio while the user resizes it.
        case uniform
        /// Any size.
        case freeform
    }

    /// Request a new size and/or resizing restriction for `scene`.
    ///
    /// - Parameters:
    ///   - scene: the window scene to resize; nil is a no-op.
    ///   - size: the requested size, or nil to leave the size alone.
    ///   - restriction: the resizing restriction, or nil to leave it alone.
    ///   - animated: whether visionOS may animate the change. Most callers
    ///     want `false` so an aspect-fit resize snaps instead of gliding.
    static func request(
        _ scene: PlatformWindowScene?,
        size: CGSize? = nil,
        restriction: ResizingRestriction? = nil,
        animated: Bool = false
    ) {
        #if os(visionOS)
        guard let scene else { return }
        let preferences: UIWindowScene.GeometryPreferences.Vision
        switch (size, restriction) {
        case let (size?, restriction?):
            preferences = .init(size: size, resizingRestrictions: restriction.uiKitValue)
        case let (size?, nil):
            preferences = .init(size: size)
        case let (nil, restriction?):
            preferences = .init(resizingRestrictions: restriction.uiKitValue)
        case (nil, nil):
            return
        }
        if animated {
            scene.requestGeometryUpdate(preferences)
        } else {
            UIView.performWithoutAnimation {
                scene.requestGeometryUpdate(preferences)
            }
        }
        #else
        _ = (scene, size, restriction, animated)
        #endif
    }
}

#if os(visionOS)
private extension WindowGeometry.ResizingRestriction {
    var uiKitValue: UIWindowScene.ResizingRestrictions {
        switch self {
        case .uniform: return .uniform
        case .freeform: return .freeform
        }
    }
}
#endif

// MARK: - Shared: status bar

extension View {
    /// visionOS has no status bar; tvOS has no status bar either (nothing to
    /// hide — the whole screen is always the app's). iOS shows one with the
    /// clock, battery and signal glyphs on top of every full-screen viewer.
    /// Hide it in sync with the ornaments so a maximized photo/video/slideshow
    /// actually uses the whole screen instead of leaving a bar of chrome
    /// behind after the rest of the UI has auto-hidden.
    func hidesStatusBar(_ hidden: Bool) -> some View {
        #if os(visionOS) || os(tvOS) || os(macOS)
        return self
        #else
        return self.statusBar(hidden: hidden)
        #endif
    }

    /// `.textSelection(.enabled)` doesn't exist on tvOS — there is no
    /// pointer/cursor to select text with from a remote. Same call everywhere
    /// else; a no-op there.
    func selectableText() -> some View {
        #if os(tvOS)
        return self
        #else
        return self.textSelection(.enabled)
        #endif
    }

    /// `.textFieldStyle(.roundedBorder)` doesn't exist on tvOS. These call
    /// sites are all in shared settings/filter views the tvOS root UI doesn't
    /// present (its own Settings is a remote-friendly subset — see
    /// Hypnos/CLAUDE.md "tvOS"), so `.plain` here is only ever exercised by
    /// dead code on tvOS; it exists to keep the module compiling.
    func roundedTextFieldStyle() -> some View {
        #if os(tvOS)
        return self.textFieldStyle(.plain)
        #else
        return self.textFieldStyle(.roundedBorder)
        #endif
    }
}

#if !os(visionOS)

// MARK: - iOS: ornaments become overlays

/// Stand-in for SwiftUI's `OrnamentAttachmentAnchor`. Only the `.scene(...)`
/// form is used in this app; the 3D anchor collapses to a 2D alignment.
struct OrnamentAttachmentAnchor {
    let alignment: Alignment

    struct SceneAnchor {
        let alignment: Alignment

        static let bottomFront = SceneAnchor(alignment: .bottom)
        static let bottom = SceneAnchor(alignment: .bottom)
        static let bottomBack = SceneAnchor(alignment: .bottom)
        static let topFront = SceneAnchor(alignment: .top)
        static let top = SceneAnchor(alignment: .top)
        static let topBack = SceneAnchor(alignment: .top)
        static let leading = SceneAnchor(alignment: .leading)
        static let leadingFront = SceneAnchor(alignment: .leading)
        static let trailing = SceneAnchor(alignment: .trailing)
        static let trailingFront = SceneAnchor(alignment: .trailing)
        static let center = SceneAnchor(alignment: .center)
    }

    static func scene(_ anchor: SceneAnchor) -> OrnamentAttachmentAnchor {
        OrnamentAttachmentAnchor(alignment: anchor.alignment)
    }
}

extension View {
    /// visionOS attaches an ornament outside the window; on iOS the same bar is
    /// laid over the content at the matching edge, inside the safe area.
    ///
    /// Bars wider than the view scroll horizontally rather than clipping —
    /// every viewer bar in this app is wider than an iPhone in portrait. A bar
    /// that wants to know about that scroll reads `\.ornamentIsScrolling`
    /// rather than attaching its own gesture; see the note on that key.
    func ornament<Content: View>(
        visibility: Visibility = .automatic,
        attachmentAnchor: OrnamentAttachmentAnchor,
        contentAlignment: Alignment = .center,
        @ViewBuilder ornament: () -> Content
    ) -> some View {
        let bar = ornament()
        // Every call site attaches to `.scene(...)`, i.e. the window — so the
        // iOS bar belongs at the screen's edge, not at the edge of whatever
        // the content happened to size itself to (a letterboxed photo would
        // otherwise float the bar across the middle of the display).
        let shown = visibility != .hidden
        return frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: attachmentAnchor.alignment) {
                // Slides in from its edge and back out, as the visionOS
                // players' chrome rises and sinks (`PlayerChromeAnimation`).
                ZStack {
                    if shown {
                        IOSOrnamentContainer(edgeAlignment: attachmentAnchor.alignment) {
                            bar
                        }
                        .transition(Self.ornamentTransition(attachmentAnchor.alignment))
                    }
                }
                .animation(shown ? PlayerChromeAnimation.reveal : PlayerChromeAnimation.hide, value: shown)
            }
    }

    private static func ornamentTransition(_ alignment: Alignment) -> AnyTransition {
        let edge: Edge? = switch alignment.vertical {
        case .top: .top
        case .bottom: .bottom
        default:
            switch alignment.horizontal {
            case .leading: .leading
            case .trailing: .trailing
            default: nil
            }
        }
        guard let edge else { return .opacity }
        return .move(edge: edge).combined(with: .opacity)
    }
}

/// Whether the ornament bar around this view is being scrolled horizontally.
///
/// It is published *down* from the scroller because a bar cannot detect the
/// drag itself: a `DragGesture(minimumDistance: 0)` attached to the scroller's
/// own content claims the touch at touch-down and the scroll view's pan never
/// begins, so every control past the screen edge becomes unreachable. Measured
/// on an iPhone 18 Pro Max, iOS 27: identical bars scrolled 171 points without
/// that gesture and 0 with it.
///
/// A bar that suppresses an auto-hide timer while the user is handling it
/// therefore observes this instead of adding a gesture of its own.
private struct OrnamentIsScrollingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var ornamentIsScrolling: Bool {
        get { self[OrnamentIsScrollingKey.self] }
        set { self[OrnamentIsScrollingKey.self] = newValue }
    }
}

/// Hosts an ornament's content as an edge overlay. Its frame hugs the content,
/// so taps outside the bar still reach whatever is underneath.
private struct IOSOrnamentContainer<Content: View>: View {
    let edgeAlignment: Alignment
    @ViewBuilder let content: () -> Content
    @State private var isScrolling = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content()
            ScrollView(.horizontal) {
                content()
                    .padding(.horizontal, 4)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .onScrollPhaseChange { _, phase in
                isScrolling = phase.isScrolling
            }
        }
        .environment(\.ornamentIsScrolling, isScrolling)
        .padding(.horizontal, 12)
        .padding(edgeAlignment == .top ? .top : .bottom, 8)
    }
}

// MARK: - iOS: glass

extension View {
    /// visionOS's window-glass backing. iOS 26 has Liquid Glass; the shape
    /// defaults to the rounded rectangle visionOS uses.
    func glassBackgroundEffect() -> some View {
        glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    func glassBackgroundEffect<S: Shape>(in shape: S) -> some View {
        glassEffect(.regular, in: shape)
    }
}

// MARK: - iOS: depth modifiers

extension View {
    /// There is no z axis on a flat display; layering is handled by ZStack order.
    func offset(z: CGFloat) -> some View {
        self
    }
}

// MARK: - iOS: ImagePresentationComponent null object

/// Null-object stand-in for RealityKit's visionOS-only spatial-photo component.
///
/// Exists so `PhotoWindowModel` and the views that read its 3D state compile
/// unchanged. Semantics: the component can be created and stored, but it has
/// no spatial content — `viewingMode` is always `.mono`, `aspectRatio(for:)`
/// is unknown, `supportedViewingModes` is empty, and every `Spatial3DImage`
/// initialiser throws `Spatial3DUnavailable`. Nothing in the iOS UI offers a
/// 3D mode (`PlatformCapabilities.supportsSpatial3D` is false), so these paths
/// are reachable only from persisted state and fail closed when they are.
struct ImagePresentationComponent: Component {
    enum ViewingMode: Hashable, Sendable {
        case mono
        case spatial3D
        case spatial3DImmersive
        case spatialStereo
        case spatialStereoImmersive
    }

    struct Spatial3DUnavailable: LocalizedError {
        var errorDescription: String? {
            "Spatial 3D conversion needs Apple Vision Pro."
        }
    }

    /// The generated-depth source. Cannot be constructed on iOS.
    final class Spatial3DImage: @unchecked Sendable {
        init(contentsOf url: URL) async throws {
            throw Spatial3DUnavailable()
        }

        init(imageSource: CGImageSource) async throws {
            throw Spatial3DUnavailable()
        }

        func generate() async throws {
            throw Spatial3DUnavailable()
        }
    }

    var desiredViewingMode: ViewingMode = .mono

    /// Always mono: nothing spatial can have been generated.
    var viewingMode: ViewingMode { .mono }

    /// Zero, the same value visionOS reports before a component has a size.
    var presentationScreenSize: SIMD2<Float> { .zero }

    init(spatial3DImage: Spatial3DImage) {}

    func aspectRatio(for mode: ViewingMode) -> Float? { nil }

    static func supportedViewingModes(for image: Spatial3DImage) -> Set<ViewingMode> { [] }
}

// MARK: - iOS: spatial audio policy

extension AVPlayerItem {
    /// visionOS restricts stereo spatialisation so audio does not anchor to
    /// the wrong window. iOS plays through the device or headphones as-is.
    /// `nonisolated` like the RAVEMedia original: callers run off the main
    /// actor (`ChunkBufferManager`).
    nonisolated func applySpatialAudioPolicy(sceneIdentifier: String? = nil) {}
}

extension AVPlayer {
    nonisolated func applySpatialAudioPolicy(for asset: AVURLAsset, sceneIdentifier: String? = nil) {}
}

#endif

// MARK: - tvOS-only: popover

#if os(tvOS)
extension View {
    /// `.popover` doesn't exist on tvOS — there's no pointer to anchor a
    /// floating panel to. The handful of shared-ornament call sites that use
    /// it (`PhotoOrnamentView`'s Adjustments, `RemoteViewerOrnamentView`'s
    /// Adjustments/Add Preset) belong to viewers the tvOS root UI never
    /// presents, so this exists purely to keep the module compiling; a sheet
    /// is the nearest tvOS-native stand-in for anything that did reach it.
    ///
    /// Scoped to exactly the `isPresented:content:` shape every call site
    /// uses, and to `#if os(tvOS)` only, so it can never shadow or ambiguate
    /// SwiftUI's real (defaulted-parameter) `popover` on iOS/visionOS.
    func popover<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        sheet(isPresented: isPresented, content: content)
    }
}
#endif

// MARK: - Shared: disclosure group

/// `DisclosureGroup` doesn't exist on tvOS — there's no pointer to click a
/// disclosure triangle with, and every call site (association chips in
/// `MediaDetailSheet`, cache/debug lists in Settings) belongs to a screen the
/// tvOS root UI doesn't present (see Hypnos/CLAUDE.md "tvOS"). tvOS gets both
/// halves shown at once, stacked, rather than a collapse that nothing can
/// reach; everywhere else this is the real `DisclosureGroup`, unchanged.
///
/// A free function rather than a `View` extension: `DisclosureGroup` is a
/// concrete type used as a value (not a modifier chained off `self`), so
/// there's no receiver to attach a same-name method to.
@ViewBuilder
func platformDisclosureGroup<Content: View, Label: View>(
    @ViewBuilder content: @escaping () -> Content,
    @ViewBuilder label: @escaping () -> Label
) -> some View {
    #if os(tvOS)
    VStack(alignment: .leading, spacing: 8) {
        label()
        content()
    }
    #else
    DisclosureGroup { content() } label: { label() }
    #endif
}

/// String-label overload, for the `DisclosureGroup("Title") { … }` call shape.
@ViewBuilder
func platformDisclosureGroup<Content: View>(
    _ titleKey: LocalizedStringKey,
    @ViewBuilder content: @escaping () -> Content
) -> some View {
    platformDisclosureGroup(content: content) { Text(titleKey) }
}
