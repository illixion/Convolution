/*
 Hypnos - the system's Picture in Picture for a player we draw ourselves

 iOS, iPadOS and macOS float a video over other apps through
 `AVPictureInPictureController`, which takes its picture from an
 `AVPlayerLayer` (or a sample-buffer display layer) in the app's window. The
 video window draws its frames through Metal, so its host keeps a layer for
 this alone (`NativeVideoHostView.pipView`), under the Metal view, with the
 window's player attached: the controller needs a layer that is on screen
 and playing, and a hidden one makes Picture in Picture impossible.

 On iOS it starts by itself when the person leaves the app while the video
 plays (`canStartPictureInPictureAutomaticallyFromInline`), as the system's
 own players do. visionOS has the Cinema HUD instead (no system Picture in
 Picture for a custom player there), and tvOS's video window is AVKit's
 player, which offers its own.
 */

#if os(iOS) || os(macOS)
import AVKit
import DebugTrace

@MainActor
final class VideoPictureInPicture: NSObject {
    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private(set) var isPossible = false
    private(set) var isActive = false
    /// Possible or active changed.
    var onChange: (_ possible: Bool, _ active: Bool) -> Void = { _, _ in }

    /// Picture in Picture from `layer`, once: the controller follows whatever
    /// player the layer is given afterwards.
    func attach(to layer: AVPlayerLayer) {
        guard controller == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let controller = AVPictureInPictureController(contentSource: .init(playerLayer: layer))
        controller.delegate = self
        #if os(iOS)
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        #endif
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] observed, _ in
            let possible = observed.isPictureInPicturePossible
            Task { @MainActor [weak self] in
                guard let self, self.isPossible != possible else { return }
                self.isPossible = possible
                self.onChange(possible, self.isActive)
            }
        }
        self.controller = controller
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        }
    }

    func stop() {
        if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
    }

    private func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        onChange(isPossible, active)
    }
}

extension VideoPictureInPicture: AVPictureInPictureControllerDelegate {
    // Active from "will start": an automatic start on iOS comes as the app
    // leaves, and the window must not pause the player for the background.
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            AppLogger.videoWindow.info("Picture in Picture starting")
            setActive(true)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            AppLogger.videoWindow.info("Picture in Picture stopped")
            setActive(false)
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: any Error) {
        MainActor.assumeIsolated {
            AppLogger.videoWindow.error("Picture in Picture failed to start: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            setActive(false)
        }
    }

    // The window is still there under the floating picture: nothing to restore.
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}
#endif
