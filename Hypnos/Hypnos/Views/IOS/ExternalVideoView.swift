#if os(iOS)
import AVFoundation
import RAVEMedia
import SwiftUI

/// The TV follows the phone's player, including seeks and renderer rebuilds.
struct ExternalVideoView: View {
    let model: VideoWindowModel

    var body: some View {
        let _ = model.nativePlayerGeneration
        ZStack {
            Color.black
            ExternalVideoLayer(player: model.nativePlayer)
                .scaleEffect(x: model.isFlipped ? -1 : 1, y: 1)
            SubtitleOverlay(controller: model.subtitles, pictureAspect: model.videoAspectRatio) {
                model.currentTime
            }
        }
        .ignoresSafeArea()
        .persistentSystemOverlays(.hidden)
    }
}

private struct ExternalVideoLayer: UIViewRepresentable {
    let player: AVPlayer?

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.videoGravity = .resizeAspect
        RAVEHDRLayer.allowHDR(on: view.playerLayer)
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }

    static func dismantleUIView(_ view: LayerView, coordinator: ()) {
        view.playerLayer.player = nil
    }

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
#endif
