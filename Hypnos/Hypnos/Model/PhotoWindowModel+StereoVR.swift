/*
 Hypnos - Photo Window Model: packed stereo and VR photos

 A photo can already be 3D: both eyes packed side by side or over under
 (`Photo_SBS.jpg`), or a VR picture (180°, 360°, fisheye) meant to be
 seen around the wearer. What it is comes from its name and shape
 (`VRFormatDetector`); the 3D menu offers every format by hand too.

 - Packed stereo: the two eyes, cut out of the frame, shown in the window
   in stereo (`RAVEPackedStereoPhotoView`), the window shaped like one eye.
   Turned on by itself for a photo that names its packing.
 - VR: the photo on a sphere around the wearer in the VR photo space
   (`VRPhotoSpace`, drawn by RAVEMedia's `RAVEVRSphere`).

 Both are exclusive with the other 3D modes; gallery navigation leaves
 them (`clearPackedStereoState`), and the next photo turns packed stereo
 on again if it names its packing.
 */

import CoreGraphics
import DebugTrace
import Foundation
import ImageIO
import RAVEUI
import RAVEMedia
import RealityKit

extension PhotoWindowModel {
    /// What the photo's name and shape say it is: a packed stereo pair (a
    /// flat projection with a layout), a VR picture, or nil.
    var detectedVRFormat: VRFormat? {
        let name = image.fileName ?? image.title ?? imageURL.lastPathComponent
        let size = nativeImageDimensions
        return VRFormatDetector.detect(fileName: name,
                                       frameWidth: size.map { Int($0.width) } ?? image.sourceWidth,
                                       frameHeight: size.map { Int($0.height) } ?? image.sourceHeight)
    }

    var isPackedStereoMode: Bool { packedStereoLayout != nil }

    /// The photo decoded for packed stereo or VR, oriented, at most 8192 px on
    /// its long side (a 16K-wide 360° still is shown at half size).
    func decodedFullPicture() async -> CGImage? {
        guard let data = currentImageData else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 8192,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }

    /// Shows the photo as the stereo pair `layout` packs, or flat again with nil.
    func setPackedStereo(_ layout: PackedStereoLayout?) async {
        recordInteraction()
        guard let layout else {
            exitPackedStereo()
            return
        }
        if isAIDepthMode || isDioramaMode || is3DMode || desiredViewingMode != .mono { await showFlat() }
        var decoded = packedStereoImage
        if decoded == nil { decoded = await decodedFullPicture() }
        guard let picture = decoded else {
            AppLogger.photoWindow.warning("Packed stereo: the photo couldn't be decoded")
            return
        }
        if aspectBeforePackedStereo == nil { aspectBeforePackedStereo = imageAspectRatio }
        packedStereoImage = picture
        packedStereoReady = false
        packedStereoLayout = layout
        #if os(visionOS)
        // The window takes one eye's shape (`WindowResizeCoalescer` follows it).
        imageAspectRatio = RAVEPackedStereoPhotoView.eyeAspect(of: picture, layout: layout)
        #endif
        AppLogger.photoWindow.info("Packed stereo on: \(layout.arrangement.rawValue, privacy: .public)\(layout.isHalfResolution ? " half" : "", privacy: .public)")
    }

    func exitPackedStereo() {
        guard packedStereoLayout != nil else { return }
        packedStereoLayout = nil
        packedStereoReady = false
        packedStereoImage = nil
        if let aspect = aspectBeforePackedStereo { imageAspectRatio = aspect }
        aspectBeforePackedStereo = nil
    }

    /// Gallery navigation and cleanup: the next photo decides for itself.
    func clearPackedStereoState() {
        packedStereoLayout = nil
        packedStereoReady = false
        packedStereoImage = nil
        aspectBeforePackedStereo = nil
    }
}

#if os(visionOS)
import SwiftUI

extension PhotoWindowModel {
    /// Puts the photo around the wearer as `format` (the VR photo space).
    func showInVR(_ format: VRFormat, open: OpenImmersiveSpaceAction) async {
        recordInteraction()
        var decoded = packedStereoImage
        if decoded == nil { decoded = await decodedFullPicture() }
        guard let picture = decoded else {
            AppLogger.photoWindow.warning("VR photo: the photo couldn't be decoded")
            return
        }
        VRPhotoPresenter.shared.present(picture, format: format, owner: self)
        if !VRPhotoPresenter.shared.isOpen {
            switch await open(id: VRPhotoPresenter.spaceID) {
            case .opened: break
            default:
                AppLogger.photoWindow.warning("VR photo: the space didn't open")
                VRPhotoPresenter.shared.clear()
                return
            }
        }
        isShowingVRPhoto = true
        // VR owns the photo session now; don't leave a hidden window acting
        // as its remote or as an accidental second presentation.
        RAVEWindowScenes.destroyAll(except: nil)
    }

    func leaveVR(dismiss: DismissImmersiveSpaceAction) async {
        isShowingVRPhoto = false
        guard VRPhotoPresenter.shared.owner === self else { return }
        VRPhotoPresenter.shared.clear()
        await dismiss()
    }
}
#endif
