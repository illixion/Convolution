/*
 Hypnos - Spatial 3D Immersive Space

 Mixed-style ImmersiveSpace that hosts a single `ImagePresentationComponent`
 entity for "Fully Immersive 3D" mode. Opened from the photo viewer when
 `AppModel.fullyImmersive3DMode` is on and the user enters Immersive 3D;
 dismissed when they leave it.

 The space owns its own IPC entity so the windowed photo viewer can stay in
 a smaller windowed presentation (or mono) while the immersive presentation
 runs alongside. The image source is identified by `imageURL` — the disk
 cache resolves it to a local file before handing it to
 `ImagePresentationComponent.Spatial3DImage`.

 Placement piggybacks on `SpatialTrackingSession` + `AnchorEntity(.head)`
 with `.once` tracking — same data class as the surface-snapping path
 we already use, no per-app worldSensing prompt. The `.once` tracking
 mode snaps the anchor to the head pose at the moment the space opens
 and then freezes it, which is exactly what we want for a "place this
 in front of where the user is looking" placement.

 Recenter (Digital Crown long-press) is detected via SwiftUI's
 `\.immersiveSpaceDisplacement` environment value — it republishes
 whenever the world origin shifts. On change we tear the head anchor
 down and re-create it, which retriggers the `.once` snap against the
 new pose.
 */

import DebugTrace
import RealityKit
import SwiftUI

/// Payload passed to `openImmersiveSpace(value:)` so the immersive scene
/// knows which image to render. Conforms to `Codable` + `Hashable` per
/// visionOS' ImmersiveSpace value requirements.
///
/// Kept outside the `#if os(visionOS)` gate below (unlike the view itself)
/// because it is a plain Codable value type referenced from HypnosApp
/// and PhotoDisplayView, both only inside their own visionOS branches — but
/// the type declaration itself costs nothing to keep available on iOS too.
struct Spatial3DImmersiveValue: Codable, Hashable {
    let imageURL: URL
}

#if os(visionOS)

struct Spatial3DImmersiveView: View {
    let value: Spatial3DImmersiveValue
    @Environment(AppModel.self) private var appModel
    /// Republished by the system whenever the immersive coordinate
    /// origin shifts (recenter, SharePlay re-anchor). We watch this for
    /// recenter detection so we don't have to spin up an ARKitSession
    /// just to listen for world-anchor updates.
    @Environment(\.immersiveSpaceDisplacement) private var immersiveSpaceDisplacement

    /// Snapshot of the photo viewer's contentEntity transferred into the
    /// immersive scene's RealityView. Captured once on appear so the
    /// `update` closure has a stable handle even if AppModel's reference
    /// is cleared mid-lifecycle. On disappear the entity is detached and
    /// AppModel's reference is left to the photo viewer to re-adopt.
    @State private var hostedEntity: Entity?
    /// Anchored to the user's head pose at the moment the space (or a
    /// post-recenter rebuild) starts. `.once` tracking freezes it after
    /// the initial snap so the image stays put in world space as the
    /// user walks around.
    @State private var headAnchor: AnchorEntity?
    /// Lightweight session that authorizes the head-anchor data. Uses
    /// the same `.world` data class as SwiftUI's surface snapping, so
    /// no separate permission prompt.
    @State private var trackingSession: SpatialTrackingSession?
    /// Bumped whenever a recenter is detected; the RealityView `update`
    /// closure reads this and rebuilds the head anchor (which has access
    /// to the RealityViewContent it can't grab from a plain `.onChange`).
    @State private var recenterTrigger: Int = 0
    @State private var lastAppliedRecenter: Int = 0

    /// Distance in metres the IPC sits in front of the user along their
    /// initial forward axis. Larger than the typical photo-window
    /// placement so the windowed controls (the original photo window,
    /// acting as the controls anchor) aren't visually obscured by the
    /// immersive presentation — pull it forward by reducing this.
    private static let placementDistance: Float = 2.0

    var body: some View {
        RealityView { content in
            await ensureTrackingAuthorized()

            // Adopt the photo viewer's IPC entity if it was handed off,
            // otherwise build a fresh one from disk as a fallback (e.g.
            // if the user re-entered immersive faster than the model
            // could repopulate the loan reference).
            let entity: Entity?
            if let loaned = appModel.immersiveLoanEntity {
                loaned.removeFromParent()
                applyImmersiveViewingMode(to: loaned)
                entity = loaned
            } else {
                entity = await buildFallbackEntity()
            }
            if let entity {
                applyUserScale(to: entity)
                entity.transform.translation = SIMD3<Float>(0, 0, -Self.placementDistance)
                hostedEntity = entity
                installHeadAnchor(in: content)
            }
        } update: { content in
            // Recenter reconcile: when the trigger advances, drop the
            // stale head anchor (its `.once` snap is now relative to the
            // pre-recenter origin) and install a fresh one. The new
            // anchor snaps against the post-recenter head pose so the
            // image returns to in-front-of-user at the current eye
            // height + yaw.
            guard recenterTrigger != lastAppliedRecenter else { return }
            lastAppliedRecenter = recenterTrigger
            guard let entity = hostedEntity else { return }
            entity.removeFromParent()
            headAnchor?.removeFromParent()
            let anchor = AnchorEntity(.head, trackingMode: .once)
            anchor.addChild(entity)
            content.add(anchor)
            headAnchor = anchor
        }
        .onChange(of: immersiveSpaceDisplacement) { _, _ in
            // Recenter: the immersive origin moved. Trip the rebuild
            // trigger so the next RealityView update reinstalls the
            // head anchor against the new pose.
            recenterTrigger &+= 1
        }
        .onChange(of: appModel.immersiveLoanOwner?.currentAdjustments.immersiveScale) { _, _ in
            // Live Distance slider updates while immersed.
            if let entity = hostedEntity { applyUserScale(to: entity) }
        }
        .onDisappear {
            // Detach the loaned entity here so the photo viewer's
            // RealityView `update` re-adopts it via its existing
            // "if parent == nil { content.add(...) }" guard.
            hostedEntity?.removeFromParent()
            headAnchor?.removeFromParent()
            headAnchor = nil
            trackingSession = nil
            // Tell the owning photo window the space went away. Covers
            // the Digital Crown dismissal path: PhotoDisplayView's
            // onChange(hostFullyImmersiveSpace) handler then runs its
            // normal cleanup (restore IPC mode, clear loan).
            if let owner = appModel.immersiveLoanOwner {
                owner.hostFullyImmersiveSpace = false
            }
        }
    }

    /// Apply the owning photo window's "Distance" (Adjustments) to the immersive
    /// entity. Higher values scale the presentation, which reads as the subject
    /// receding within the portal — hence the "Distance" label.
    @MainActor
    private func applyUserScale(to entity: Entity) {
        let s = Float(appModel.immersiveLoanOwner?.currentAdjustments.immersiveScale ?? 1.0)
        entity.scale = SIMD3<Float>(s, s, 1)
    }

    @MainActor
    private func applyImmersiveViewingMode(to entity: Entity) {
        guard var ipc = entity.components[ImagePresentationComponent.self] else { return }
        ipc.desiredViewingMode = .spatial3DImmersive
        entity.components.set(ipc)
    }

    @MainActor
    private func ensureTrackingAuthorized() async {
        guard trackingSession == nil else { return }
        // `.world` covers the head-anchor data we need. SwiftUI's
        // surface-snapping path uses the same class — visionOS reads
        // NSWorldSensingUsageDescription from Info.plist and grants
        // without prompting, just like the snapping case.
        let session = SpatialTrackingSession()
        let config = SpatialTrackingSession.Configuration(tracking: [.world])
        _ = await session.run(config)
        trackingSession = session
    }

    @MainActor
    private func installHeadAnchor(in content: RealityViewContent) {
        guard let entity = hostedEntity else { return }
        let anchor = AnchorEntity(.head, trackingMode: .once)
        anchor.addChild(entity)
        content.add(anchor)
        headAnchor = anchor
    }

    @MainActor
    private func buildFallbackEntity() async -> Entity? {
        guard let sourceURL = await PhotoWindowModel.localFileURL(for: value.imageURL) else {
            AppLogger.photoWindow.warning("Spatial3DImmersiveView: no local file for \(value.imageURL.loggableDescription)")
            return nil
        }

        do {
            let spatial3DImage: ImagePresentationComponent.Spatial3DImage
            let cap = appModel.spatial3DMaxResolution
            if cap > 0,
               let data = PhotoWindowModel.createDownsampledImageData(from: sourceURL, maxDimension: CGFloat(cap)),
               let source = CGImageSourceCreateWithData(data as CFData, nil) {
                spatial3DImage = try await ImagePresentationComponent.Spatial3DImage(imageSource: source)
            } else {
                spatial3DImage = try await ImagePresentationComponent.Spatial3DImage(contentsOf: sourceURL)
            }
            var ipc = ImagePresentationComponent(spatial3DImage: spatial3DImage)
            ipc.desiredViewingMode = .spatial3DImmersive
            let entity = Entity()
            entity.components.set(ipc)
            try await spatial3DImage.generate()
            return entity
        } catch {
            AppLogger.photoWindow.error("Spatial3DImmersiveView: failed to load Spatial3DImage: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            return nil
        }
    }
}

#endif
