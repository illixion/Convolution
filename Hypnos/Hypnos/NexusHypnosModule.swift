//
//  NexusHypnosModule.swift
//  Hypnos
//
//  Hypnos (Convolution) as a module of Nexus (`~/Projects/Nexus`), which runs several apps in one
//  process so they can share one immersive space. Compiled only into Nexus's framework build of
//  this folder (`NEXUS_MODULE`); this app's own build has none of it. See docs/nexus-module.md.
//
//  The module joins the host's shared space instead of opening its own: the cinema's content is
//  `CinemaSpace`'s root mounted under the root the host gives it, and the host's gestures on that
//  root come back to `CinemaSpace`. Its windows are `HypnosWindows`, with ids prefixed "hypnos.".
//

#if os(visionOS) && NEXUS_MODULE

import DebugTrace
import Observation
import RAVESharedSpace
import RealityKit
import SwiftUI
import VideoToolbox

@MainActor
public final class HypnosSpaceModule: RAVESpaceModule, CinemaSpaceHosting {
    public let id = "hypnos"
    public let name = "Convolution"
    public let systemImage = "film"
    public var mainWindowID: String { HypnosSceneID.main }

    /// The subsystem this module logs under, for the host's `DebugTrace.configure`.
    public static var logSubsystem: String { AppLogger.subsystem }

    let appModel: AppModel
    private let space = CinemaSpace()
    private weak var host: RAVESpaceHost?

    public init() {
        // What `HypnosApp.init` does once at launch, bar what belongs to the host (the debug
        // server and its configuration).
        FilmDebugEndpoints.register()
        VideoPlayerDebugEndpoints.register()
        PhotoStereoDebugEndpoints.register()
        InterpolationDebugEndpoints.register()
        appModel = AppModel()
        LibraryDownloads.shared.start()
        if #available(visionOS 26.2, *) {
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
        }
        Cinema.shared.spaceHost = self
    }

    /// Hand the module its host; until then it can't join.
    public func attach(to host: RAVESpaceHost) {
        self.host = host
    }

    // MARK: CinemaSpaceHosting

    func joinCinemaSpace() async -> Bool {
        guard let host else { return false }
        host.broker.request(id, requirements)
        followRequirements()
        // Mounting sets the cinema open (`CinemaSpace.appeared`).
        for _ in 0..<100 {
            if Cinema.shared.isOpen { return true }
            if !host.broker.contains(id) { return false }
            if host.broker.phase == .closed, host.broker.lastError != nil { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return Cinema.shared.isOpen
    }

    func leaveCinemaSpace() async {
        host?.broker.release(id)
        // Unmounting runs `CinemaSpace.disappeared`.
        for _ in 0..<50 where Cinema.shared.isOpen {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// What the cinema asks of the shared space: the room dark around Big Screen.
    private var requirements: RAVESpaceRequirements {
        RAVESpaceRequirements(immersion: .mixed, hidesUpperLimbs: false,
                              surroundings: space.wantsDarkSurroundings ? .systemDark : nil,
                              needsHands: false)
    }

    /// Keep the broker's copy of the requirements current while the module is in the space,
    /// without moving it to the newest place (that would take immersion from whoever joined
    /// after it).
    private func followRequirements() {
        guard let host, host.broker.contains(id) else { return }
        let current = withObservationTracking { requirements } onChange: { [weak self] in
            Task { @MainActor in self?.followRequirements() }
        }
        host.broker.update(id, current)
    }

    // MARK: RAVESpaceModule

    public func mount(_ root: Entity, services: RAVESpatialServices) async {
        space.build(appModel: appModel)
        root.addChild(space.root)
        space.appeared()
    }

    public func unmount() {
        space.disappeared()
        space.root.removeFromParent()
    }

    public func tapped(_ value: EntityTargetValue<SpatialTapGesture.Value>) { space.tapped(value) }
    public func dragChanged(_ value: EntityTargetValue<DragGesture.Value>) { space.dragChanged(value) }
    public func dragEnded(_ value: EntityTargetValue<DragGesture.Value>) { space.dragEnded(value) }

    public func spaceTakenAway() {
        // The Digital Crown, or another app's space: the cinema is closed under its owner.
        space.disappeared()
        space.root.removeFromParent()
    }
}

/// Hypnos's windows, for the host's `App.body`. Every one carries the "hypnos." id prefix.
public struct HypnosModuleScenes: SwiftUI.Scene {
    let module: HypnosSpaceModule

    public init(module: HypnosSpaceModule) { self.module = module }

    public var body: some SwiftUI.Scene {
        HypnosWindows(appModel: module.appModel)
    }
}

#endif
