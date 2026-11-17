/*
 Hypnos - the chrome a player window hangs on its picture (visionOS)

 The video window and the film player wear the same chrome, and this is the
 one place it is laid out: the control strip under the window (with the
 subtitle band and the prompt above it), the title over the top-left corner
 and the playback info panel over the top-right one. Each player brings its
 own strip, title and panel; where they hang, how far they stand off a 3D
 picture and how they rise and sink are decided here, so the two can't drift
 apart again (the film player went without the playback info panel, with a
 different strip gap and title lift, while the video window had them).
 */

import SwiftUI

#if os(visionOS)
extension View {
    /// - Parameters:
    ///   - isPresented: the chrome is up (not hidden, and the player isn't in the HUD).
    ///   - canMount: false when nothing of the window may show (every window hidden).
    ///   - showsInfo: the playback info panel is wanted (Settings → Videos → Playback Info).
    ///   - stereo: a 3D picture is showing, which the chrome stands further off.
    ///   - subtitles: the subtitles hung under the picture, above the strip.
    ///   - prompt: the skip button and notices beside the strip; nil while the HUD has them.
    ///   - onStripHeight: the strip stack's height, for a window that sizes itself around it.
    func playerWindowChrome<Strip: View, Title: View, Info: View>(
        isPresented: Bool,
        canMount: Bool = true,
        showsInfo: Bool,
        stereo: Bool,
        subtitles: SubtitleController?,
        prompt: AnyView?,
        filmTime: @escaping @MainActor () -> Double,
        onStripHeight: ((CGFloat) -> Void)? = nil,
        @ViewBuilder strip: @escaping () -> Strip,
        @ViewBuilder title: @escaping () -> Title,
        @ViewBuilder info: @escaping () -> Info
    ) -> some View {
        // Hung under the window, outside it: the window holds only the
        // picture, and the system moves the window bar below the ornament.
        // The strip rises into place and sinks away (`playerChromeOrnament`).
        self
            .playerChromeOrnament(
                isPresented: isPresented && canMount,
                keepsMounted: canMount && PlayerOrnamentStack<EmptyView>.keepsMounted(
                    subtitles: subtitles, hasPrompt: prompt != nil),
                attachmentAnchor: .scene(.bottom),
                contentAlignment: .top
            ) { shown in
                PlayerOrnamentStack(
                    subtitles: subtitles, controlsVisible: shown, prompt: prompt,
                    gap: stereo ? PlayerWindowChromeMetrics.stereoControlsGap : 12,
                    filmTime: filmTime
                ) { strip() }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onStripHeight?($0) }
            }
            // The title over the window's top-left corner, with the controls.
            .playerChromeOrnament(
                isPresented: isPresented && canMount,
                attachmentAnchor: .scene(.topLeading),
                contentAlignment: .topLeading
            ) { shown in
                title().padding(20)
                    .modifier(PlayerChromeReveal(shown: shown, edge: .top))
                    .offset(z: stereo ? PlayerChromeAnimation.stereoTitleLift : 0)
            }
            // How the picture gets here, over the other top corner.
            .playerChromeOrnament(
                isPresented: isPresented && canMount && showsInfo,
                attachmentAnchor: .scene(.topTrailing),
                contentAlignment: .topTrailing
            ) { shown in
                info().padding(20)
                    .modifier(PlayerChromeReveal(shown: shown, edge: .top))
                    .offset(z: stereo ? PlayerChromeAnimation.stereoTitleLift : 0)
            }
    }
}
#endif

/// Sizes shared by every player window's chrome.
enum PlayerWindowChromeMetrics {
    /// The strip stands further below a 3D picture, whose depth reaches toward it.
    static let stereoControlsGap: CGFloat = 44
    /// The strip follows the window's width within these limits.
    static let minimumStripWidth: CGFloat = 760
    static let maximumStripWidth: CGFloat = 1180

    /// The strip's width for a window this wide (in 20 pt steps); nil before it is known.
    static func stripWidth(forWindowWidth width: CGFloat) -> CGFloat? {
        width > 0 ? min(max(width, minimumStripWidth), maximumStripWidth) : nil
    }
}
