/*
 Hypnos - VR photos around the wearer

 A 180°, 360° or fisheye photo (mono or packed side by side / over under)
 on RAVEMedia's `RAVEVRSphere` in a mixed immersive space of its own,
 centred on the head where it opened and facing the way the wearer looked
 (a head anchor that tracks once). The source photo window closes while the
 VR space is active; a sleeve remote recenters or returns to a fresh photo
 window. The app has one immersive space at a time, so opening this one
 closes the cinema or Spatial 3D's.
 */

#if os(visionOS)
import DebugTrace
import RAVEPanel
import RAVEUI
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
    @ObservationIgnored private(set) var owner: PhotoWindowModel?

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

@MainActor
private final class VRPhotoSleeveRemote: SleeveRemote {
    private enum Tile {
        static let title = "vrPhoto.title"
        static let recenter = "vrPhoto.recenter"
        static let window = "vrPhoto.window"
    }

    private enum Action {
        static let recenter = "vrPhoto.recenter"
        static let window = "vrPhoto.window"
    }

    let kind = "vr-photo"
    let layout = RAVESleeveLayout(outer: [
        RAVESleevePage("vrPhoto", title: "VR Photo", rows: [
            [RAVESleeveTile(Tile.title, .label, span: 4)],
            [
                RAVESleeveTile(Tile.recenter, .button(RAVESleeveAction(Action.recenter)), label: "Recenter", icon: "scope", span: 2),
                RAVESleeveTile(Tile.window, .button(RAVESleeveAction(Action.window)), label: "Window", icon: "rectangle.on.rectangle", span: 2),
            ],
        ]),
    ])

    private let returnToWindow: @MainActor () -> Void

    init(returnToWindow: @escaping @MainActor () -> Void) {
        self.returnToWindow = returnToWindow
    }

    var isActive: Bool { VRPhotoPresenter.shared.picture != nil }

    func refresh(_ wearer: RAVESleeveWearer) {
        let presenter = VRPhotoPresenter.shared
        let projection = presenter.format?.projection.label ?? "VR"
        set(wearer, Tile.title, RAVESleeveTileState(text: "VR Photo · \(projection)"))
    }

    func handle(_ event: RAVESleeveEvent, _ wearer: RAVESleeveWearer) {
        guard event.kind == .fired, let action = event.action else { return }
        switch action.id {
        case Action.recenter: VRPhotoPresenter.shared.recenter()
        case Action.window: returnToWindow()
        default: break
        }
    }
}

struct VRPhotoSpaceView: View {
    @State private var sphere = RAVEVRSphere()
    @State private var anchor = AnchorEntity(.head, trackingMode: .once)
    @State private var root = Entity()
    @OpenWindowProxy private var openWindow
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var returningToWindow = false
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
        .onAppear {
            presenter.noteOpen(true)
            if let owner = presenter.owner {
                let remote = VRPhotoSleeveRemote { [weak owner] in
                        guard let owner else { return }
                        Task { await returnToPhotoWindow(owner) }
                }
                ForearmSleeve.shared.spaceOpened(remote)
                ForearmSleeve.shared.attach(to: root)
            }
        }
        .onDisappear {
            let owner = presenter.owner
            ForearmSleeve.shared.spaceClosed()
            sphere.stop()
            presenter.noteOpen(false)
            if !returningToWindow, let owner {
                Task { await returnToPhotoWindow(owner) }
            }
        }
    }

    @MainActor
    private func returnToPhotoWindow(_ owner: PhotoWindowModel) async {
        guard !returningToWindow else { return }
        returningToWindow = true
        presenter.clear()
        _ = await owner.depositSpatial3DForHandoff()
        openWindow(id: HypnosSceneID.photoDetail, value: PhotoWindowValue(image: owner.image))
        await dismissImmersiveSpace()
        owner.cleanup()
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
