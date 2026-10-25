/*
 Hypnos - tvOS animated pictures

 tvOS has no WebKit, which the other platforms animate GIF, WebP and JPEG XL
 pictures with (`AnimatedImageWebView`, `AnimatedJXLWebView`), so the Apple
 TV photo viewer plays them with ImageIO itself: `CGAnimateImageDataWithBlock`
 hands over one decoded frame at a time, on the main queue, with the file's
 own frame delays and loop count, and the view shows each in a
 `UIImageView`. Memory stays at the encoded file plus the frame on screen:
 nothing is decoded ahead, and leaving the picture stops the animation.

 ImageIO animates GIF, APNG, animated WebP and HEIF sequences. It decodes
 only the first frame of an animated JPEG XL (`CGImageSourceGetCount` says
 1), so such a file stays still here, as it did before.
 */

#if os(tvOS)

import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum TVAnimatedImage {
    /// Whether `data` is a picture ImageIO can animate: more than one frame,
    /// in a format whose frames are an animation rather than a collection.
    static func isAnimated(_ data: Data) -> Bool {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetCount(source) > 1,
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier) else { return false }
        return [UTType.gif, .png, .webP].contains { type.conforms(to: $0) }
            || ["public.heics", "public.avis", "public.jpeg-xl"].contains(identifier)
    }
}

/// Plays an animated picture's frames, fitted to the view. `poster` (the
/// first frame, already decoded) shows until the first frame arrives.
struct TVAnimatedImageView: UIViewRepresentable {
    let data: Data
    let poster: UIImage?

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView(image: poster)
        view.contentMode = .scaleAspectFit
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        context.coordinator.start(data, in: view)
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {}

    static func dismantleUIView(_ view: UIImageView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var isStopped = false

        func start(_ data: Data, in view: UIImageView) {
            CGAnimateImageDataWithBlock(data as CFData, nil) { [weak self, weak view] _, frame, stop in
                guard let self, !self.isStopped, let view else {
                    stop.pointee = true
                    return
                }
                // ImageIO calls back on the main queue; anything else would
                // be a UIKit view touched off it.
                let image = UIImage(cgImage: frame)
                if Thread.isMainThread {
                    view.image = image
                } else {
                    DispatchQueue.main.async { view.image = image }
                }
            }
        }

        func stop() {
            isStopped = true
        }
    }
}

#endif
