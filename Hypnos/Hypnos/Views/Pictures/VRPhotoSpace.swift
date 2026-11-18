/*
 Hypnos - VR photos around the wearer

 A 180°, 360° or fisheye photo (mono or packed side by side / over under)
 on RAVEMedia's `RAVEVRSphere` in a mixed immersive space of its own,
 centred on the head where it opened and facing the way the wearer looked
 (a head anchor that tracks once). The photo window that sent it keeps its
 controls; its 3D menu's Leave VR, a new photo or closing the window takes
 it away. The app has one immersive space at a time, so opening this one
 closes the cinema or Spatial 3D's.
 */

#if os(visionOS)
import DebugTrace
import RAVEMedia
import RealityKit
import SwiftUI

@MainActor
@Observable
final class VRPhotoPresenter {
    static let shared = VRPhotoPresenter()
    static let spaceID = "VRPhotoSpace"

    private(set) var picture: CGImage?
    private(set) var format: VRFormat?
    /// Bumped for every picture, so the space reloads even for the same one.
    private(set) var generation = 0
    private(set) var isOpen = false
    /// Recentring asks the space to take the head's pose again.
    private(set) var recenterRequests = 0
    @ObservationIgnored private(set) weak var owner: PhotoWindowModel?

    func present(_ picture: CGImage, format: VRFormat, owner: PhotoWindowModel) {
        if let previous = self.owner, previous !== owner { previous.isShowingVRPhoto = false }
        self.picture = picture
        self.format = format
        self.owner = owner
        generation += 1
    }

    func recenter() { recenterRequests += 1 }

    func clear() {
        owner?.isShowingVRPhoto = false
        picture = nil
        format = nil
        owner = nil
    }

    fileprivate func noteOpen(_ open: Bool) {
        isOpen = open
        if !open { clear() }
    }
}

struct VRPhotoSpaceView: View {
    @State private var sphere = RAVEVRSphere()
    @State private var anchor = AnchorEntity(.head, trackingMode: .once)
    @State private var root = Entity()
    private let presenter = VRPhotoPresenter.shared

    var body: some View {
        RealityView { content in
            root.addChild(anchor)
            anchor.addChild(sphere.entity)
            content.add(root)
        }
        .task(id: presenter.generation) { await load() }
        .onChange(of: presenter.recenterRequests) {
            // A fresh once-tracking anchor snaps to the head's pose now.
            anchor.removeFromParent()
            let fresh = AnchorEntity(.head, trackingMode: .once)
            fresh.addChild(sphere.entity)
            root.addChild(fresh)
            anchor = fresh
        }
        .onChange(of: presenter.picture == nil) { _, cleared in
            // Its window closed or left VR: nothing stays on the sphere.
            if cleared { sphere.stop() }
        }
        .onAppear { presenter.noteOpen(true) }
        .onDisappear {
            sphere.stop()
            presenter.noteOpen(false)
        }
    }

    private func load() async {
        guard let picture = presenter.picture, let format = presenter.format else { return }
        await sphere.setFormat(format)
        do {
            try await sphere.show(image: picture)
            AppLogger.photoWindow.info("VR photo: \(format.projection.label, privacy: .public), \(format.layout.map { $0.arrangement.rawValue } ?? "mono", privacy: .public), \(picture.width, privacy: .public)×\(picture.height, privacy: .public)")
        } catch {
            AppLogger.photoWindow.error("VR photo failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
        }
    }
}
#endif
