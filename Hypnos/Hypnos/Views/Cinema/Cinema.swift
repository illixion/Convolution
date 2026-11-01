/*
 Hypnos - the cinema: one immersive space for every player

 A window can't see the head and is held to the system's placement limits,
 so the players can open a mixed immersive space (`Cinema.spaceID`) that does
 what a window can't. One player owns it at a time (`CinemaOwner`): the film
 player or one video window, whichever chose a Cinema mode last; the one it
 took over from goes back to its window.

 - **Room Sound** (film player only): the object audio's stage moves into the
   space and is centred on the wearer's real head (ARKit's device anchor,
   which only an open immersive space receives), facing the film window. The
   window's pose comes from an entity in it (`FilmWindowMarker`) read with
   `transformMatrix(relativeTo: .immersiveSpace)`. The picture stays in the
   window. A video window's sound is visionOS's own, so it has no Room Sound.
 - **Big Screen**: the picture moves onto a screen in the space,
   `screenDistance` metres ahead and `screenWidthDegrees` wide, further and
   larger than a window may go. The film moves its own `videoEntity` (same
   component and renderer, nothing reloads); a video window lends its
   `AVPlayer` to a `VideoPlayerComponent` here, its own picture hidden but
   still mounted, and a WebKit-decoded source (WebM) first switches to the
   server's transcode as AI 3D does. The surroundings dim as in Apple's
   players, the window shows a card with the way back, and the film's room
   has the screen as its front wall. Live 3D and AI 3D move their stereo
   plane onto the screen the same way (the engine lends it and takes it back).
 - **Head-Locked Sound** (`headLocked`, one setting for every player): the
   sound turns with the head instead of staying in the room. A video window's
   5.1/7.1 becomes `.fixed` spatial audio (`RAVEMediaPolicy.headLockedSurround`,
   which every playing `AVPlayer` follows); stereo already plays unspatialized.
   The film's object room is set to the head's pose every frame, which needs
   the space, so a film with head-locked sound opens it even in Window mode.

 The space asks to coexist with a system environment
 (`immersiveEnvironmentBehavior(.coexist)`, visionOS 26), so Mount Hood and
 the rest stay up around the screen. Our own windows stay visible in our
 mixed space; other apps' windows hide while it is open. An app has one
 immersive space at a time, so opening the cinema closes Spatial 3D or the
 immersive video player first.

 The room follows the head's position slowly (1.5 s), so leaning gives a
 little parallax and walking re-centres it. Positions are set in scene
 space, which in an immersive space is ARKit's origin.

 Subtitles go on the screen too: the owner's `SubtitleController` drawn by
 the same overlay as in its window, as a view attachment scaled to the
 screen. A video window going to its next episode keeps Big Screen: its
 picture stays hidden behind the card for as long as Big Screen is chosen,
 the screen keeps the last picture until the new player is lent, and while
 it holds the screen the window doesn't start AI 3D or a stereo episode's
 3D on its own (`VideoWindowModel.holdsBigScreen`).
 */

#if os(visionOS)
import ARKit
import AudioToolbox
import AVFoundation
import Combine
import DebugTrace
import QuartzCore
import RAVEFilm
import RAVEMedia
import RAVEUI
import RealityKit
import simd
import SwiftUI

enum CinemaMode: String, CaseIterable, Identifiable {
    /// No space: picture and sound in the window.
    case window
    /// The film's object audio around the head; the picture stays in the window.
    case roomSound
    /// The picture on a screen in the space.
    case bigScreen
    case hud

    var showsPicture: Bool { self == .bigScreen || self == .hud }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .window: "Window"
        case .roomSound: "Room Sound"
        case .bigScreen: "Big Screen"
        case .hud: "HUD"
        }
    }
}

/// What the screen's subtitles come from: the owner's controller and clock.
struct CinemaSubtitles {
    let controller: SubtitleController
    let time: @MainActor () -> Double
}

/// Which player the space is serving.
enum CinemaOwner: Equatable {
    case film
    case video(ObjectIdentifier)

    var modes: [CinemaMode] {
        switch self {
        case .film: CinemaMode.allCases
        case .video: [.window, .bigScreen, .hud]
        }
    }
}

@MainActor
@Observable
final class Cinema {
    static let shared = Cinema()
    static let spaceID = "CinemaSpace"

    private(set) var owner: CinemaOwner?
    /// The owner's mode; every other player is in its window.
    private(set) var mode = CinemaMode.window
    /// The space's view is up.
    private(set) var isOpen = false
    /// The space's screen holds the owner's picture, so its window doesn't.
    private(set) var screenAttached = false
    /// The screen's centre (+z toward the viewer), in the space; nil until
    /// a head pose placed it.
    private(set) var screenPose: simd_float4x4?
    /// A video window's player, shown on the screen through a `VideoPlayerComponent`.
    private(set) var screenPlayer: AVPlayer?
    /// A video window's stereo picture (live 3D or AI 3D), whose plane the
    /// screen borrows from the engine; preferred over `screenPlayer`.
    private(set) var screenStereo: Pseudo3DStereoEngine?
    /// The owner's subtitles, drawn on the screen.
    private(set) var screenSubtitles: CinemaSubtitles?
    /// Taps on the screen, for the owner's window to toggle its controls.
    private(set) var screenTaps = 0
    private(set) var status = "Closed"
    var hudOffset = SIMD3<Float>(0, 0, -2)
    var hudWidth: Float = 2 * 2 * tanf(55 * .pi / 360)
    /// The picture's aspect, reported by the space each frame so the framing
    /// knows how tall it is.
    @ObservationIgnored var hudAspect: Float = 16 / 9

    /// Moves the HUD to `offset`, held where the whole picture stays in view
    /// (`HUDFraming`).
    func moveHUD(to offset: SIMD3<Float>) {
        guard offset.x.isFinite, offset.y.isFinite, offset.z.isFinite else { return }
        hudOffset = HUDFraming.clamp(offset: offset, requestedWidth: hudWidth, aspect: hudAspect)
    }

    /// Pulls the offset back inside the view after the picture's size or shape
    /// changed (a resize, a new aspect), writing only when it moved.
    func refitHUD() {
        let fitted = HUDFraming.clamp(offset: hudOffset, requestedWidth: hudWidth, aspect: hudAspect)
        if simd_distance(fitted, hudOffset) > 1e-4 { hudOffset = fitted }
    }

    func recenterHUD() {
        hudOffset = SIMD3(0, 0, -2)
        hudWidth = 4 * tanf(55 * .pi / 360)
    }

    /// How far the HUD's smoothed head may lag the real one right now.
    var hudLagLimits: (rotation: Float, position: Float) {
        HUDFraming.lagLimits(offset: hudOffset, requestedWidth: hudWidth, aspect: hudAspect)
    }

    /// The width the picture is drawn at. The HUD keeps the width it was given
    /// until it is near enough to fill too much of the view, then keeps its
    /// angular size instead, so a close picture shrinks rather than overflows.
    var pictureWidth: Float {
        mode == .hud
            ? HUDFraming.pictureWidth(requested: hudWidth, aspect: hudAspect, distance: simd_length(hudOffset))
            : screenWidth
    }
    weak var hudVideoModel: VideoWindowModel?
    var hudControlsView: AnyView?
    var hudCloseAction: (@MainActor () -> Void)?
    var hudFilmChromeVisible = true

    /// The sound turns with the head (see the header).
    private(set) var headLocked = false
    /// Metres from the head to the screen.
    var screenDistance: Float = 15 {
        didSet { save(); refitScreen() }
    }
    /// How much of the view the screen's width takes, in degrees.
    var screenWidthDegrees: Float = 55 {
        didSet { save() }
    }
    /// Dim passthrough (or the environment) while the screen is up.
    var dimsSurroundings = true {
        didSet { save() }
    }

    /// The film window's centre in the space, from `FilmWindowMarker`.
    @ObservationIgnored var windowPose: simd_float4x4?
    @ObservationIgnored private(set) var headPose: simd_float4x4?
    /// Where the room is centred: the head, smoothed.
    @ObservationIgnored private(set) var listener: SIMD3<Float>?
    /// The film room's pose for `FilmStageView(roomPose:)`.
    @ObservationIgnored private(set) var roomPose: simd_float4x4?
    @ObservationIgnored private var arSession: ARKitSession?
    @ObservationIgnored private var worldTracking: WorldTrackingProvider?
    @ObservationIgnored private var loop: Task<Void, Never>?

    private let logger = DebugLogger(subsystem: "com.illixion.hypnos", category: "Cinema")
    private static let defaultsKey = "filmPlayer.cinema"
    /// Seconds the room takes to follow the head's position.
    private static let followSeconds: Float = 1.5

    private struct Settings: Codable {
        var screenDistance: Float
        var screenWidthDegrees: Float
        var dimsSurroundings: Bool
        /// Optional: settings saved before it existed decode as off.
        var headLocked: Bool?
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let settings = try? JSONDecoder().decode(Settings.self, from: data) {
            screenDistance = settings.screenDistance
            screenWidthDegrees = settings.screenWidthDegrees
            dimsSurroundings = settings.dimsSurroundings
            headLocked = settings.headLocked ?? false
        }
        RAVEMediaPolicy.headLockedSurround = headLocked
    }

    private func save() {
        let settings = Settings(screenDistance: screenDistance, screenWidthDegrees: screenWidthDegrees,
                                dimsSurroundings: dimsSurroundings, headLocked: headLocked)
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    /// The screen's width in metres at its distance.
    var screenWidth: Float { 2 * screenDistance * tanf(screenWidthDegrees * .pi / 360) }

    func mode(for owner: CinemaOwner) -> CinemaMode { self.owner == owner ? mode : .window }

    /// The owner's picture is on the big screen, so its window shows the card.
    func showsScreen(for owner: CinemaOwner) -> Bool { self.owner == owner && screenAttached }

    /// A video window keeps its picture hidden for as long as Big Screen is
    /// chosen, through a renderer switch or the next episode, so it never
    /// flashes back into the window between players.
    func hidesPicture(for owner: CinemaOwner) -> Bool {
        guard self.owner == owner else { return false }
        if case .video = owner { return mode.showsPicture }
        return screenAttached
    }

    /// The film's object audio plays in the space rather than its window.
    var hostsFilmSound: Bool { isOpen && owner == .film }

    private var needsSpace: Bool {
        switch owner {
        case .film: mode != .window || headLocked
        case .video: mode.showsPicture
        case nil: false
        }
    }

    // MARK: Choosing

    func setMode(_ newMode: CinemaMode, for owner: CinemaOwner,
                 open: OpenImmersiveSpaceAction, dismiss: DismissImmersiveSpaceAction) async {
        claim(owner)
        guard newMode != mode else { return }
        logger.info("Cinema: \(self.mode.rawValue, privacy: .public) → \(newMode.rawValue, privacy: .public)")
        // The window takes the picture back before anything closes.
        if !newMode.showsPicture { screenAttached = false }
        mode = newMode
        if newMode == .bigScreen, let headPose { placeScreen(facing: headPose) }
        await sync(open: open, dismiss: dismiss)
    }

    func setHeadLocked(_ locked: Bool, for owner: CinemaOwner,
                       open: OpenImmersiveSpaceAction, dismiss: DismissImmersiveSpaceAction) async {
        if headLocked != locked {
            headLocked = locked
            save()
            RAVEMediaPolicy.headLockedSurround = locked
            logger.info("Cinema: head-locked sound \(locked ? "on" : "off", privacy: .public)")
        }
        // Only the film's sound needs the space for it.
        guard owner == .film else { return }
        if self.owner != .film {
            guard locked else { return }
            claim(.film)
        }
        await sync(open: open, dismiss: dismiss)
    }

    /// A video window lends the player its picture plays on (nil while it
    /// has none, such as during a renderer switch).
    /// The screen keeps showing the last player's picture until the next
    /// one is lent, so an episode change doesn't blank it.
    func setScreenPlayer(_ player: AVPlayer?, for owner: CinemaOwner) {
        guard self.owner == owner, screenPlayer !== player else { return }
        screenPlayer = player
    }

    /// A video window lends its stereo engine's picture (nil to go back to
    /// its player's).
    func setScreenStereo(_ engine: Pseudo3DStereoEngine?, for owner: CinemaOwner) {
        guard self.owner == owner, screenStereo !== engine else { return }
        screenStereo = engine
    }

    /// Nil when the picture draws its own (a stereo picture's are in it).
    func setSubtitles(_ subtitles: CinemaSubtitles?, for owner: CinemaOwner) {
        guard self.owner == owner else { return }
        screenSubtitles = subtitles
    }

    /// The owner's window closed: the space closes with it.
    func release(_ owner: CinemaOwner, dismiss: DismissImmersiveSpaceAction) async {
        guard self.owner == owner else { return }
        resetOwner()
        if isOpen { await dismiss() }
    }

    /// Says why Big Screen can't be had for this video and goes back to the window.
    func fail(_ reason: String, for owner: CinemaOwner, dismiss: DismissImmersiveSpaceAction) async {
        guard self.owner == owner else { return }
        logger.info("Cinema: \(reason, privacy: .public)")
        status = reason
        mode = .window
        screenAttached = false
        screenPlayer = nil
        screenStereo = nil
        if !needsSpace, isOpen { await dismiss() }
    }

    private func claim(_ owner: CinemaOwner) {
        guard self.owner != owner else { return }
        if self.owner != nil { logger.info("Cinema: another player takes the space") }
        resetOwner()
        self.owner = owner
    }

    private func resetOwner() {
        owner = nil
        mode = .window
        screenAttached = false
        screenPlayer = nil
        screenStereo = nil
        screenSubtitles = nil
        hudVideoModel = nil
        hudControlsView = nil
        hudCloseAction = nil
        screenPose = nil
    }

    private func sync(open: OpenImmersiveSpaceAction, dismiss: DismissImmersiveSpaceAction) async {
        guard needsSpace else {
            if isOpen { await dismiss() }
            return
        }
        guard !isOpen else { return }
        // One immersive space at a time: Spatial 3D or the immersive video
        // player closes first (a no-op when none is open).
        await dismiss()
        status = "Opening"
        switch await open(id: Self.spaceID) {
        case .opened:
            break
        case .userCancelled:
            logger.info("Cinema: the viewer declined the space")
            fallBackToWindow("Declined")
        case .error:
            logger.error("Cinema: the space failed to open")
            fallBackToWindow("Failed to open")
        @unknown default:
            fallBackToWindow("Failed to open")
        }
    }

    private func fallBackToWindow(_ reason: String) {
        mode = .window
        screenAttached = false
        status = reason
    }

    /// Puts the screen straight ahead of the head's current heading.
    func placeScreenInFront() {
        guard let headPose else { return }
        placeScreen(facing: headPose)
    }

    // MARK: The space's lifecycle (CinemaSpaceView)

    fileprivate func spaceAppeared() {
        isOpen = true
        status = "Waiting for head tracking"
        // The space's origin is the floor at the wearer's feet: ear height
        // until the head is tracked.
        roomPose = Self.pose(at: SIMD3(0, 1.5, 0), forward: SIMD3(0, 0, -1), fallback: SIMD3(0, 0, -1))
        let session = ARKitSession()
        let tracking = WorldTrackingProvider()
        arSession = session
        worldTracking = tracking
        Task {
            do {
                try await session.run([tracking])
            } catch {
                logger.error("Cinema: head tracking failed: \(error.localizedDescription, privacy: .public)")
                status = "No head tracking"
            }
        }
        loop?.cancel()
        loop = Task { @MainActor [weak self] in
            var last = CACurrentMediaTime()
            while !Task.isCancelled {
                let now = CACurrentMediaTime()
                self?.update(dt: Float(now - last))
                last = now
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    fileprivate func spaceDisappeared() {
        logger.info("Cinema: space closed")
        loop?.cancel()
        loop = nil
        arSession?.stop()
        arSession = nil
        worldTracking = nil
        isOpen = false
        // Closed from outside (the Digital Crown): every player is back in its window.
        mode = .window
        screenAttached = false
        screenPlayer = nil
        if owner == .film && headLocked { owner = nil }
        headPose = nil
        listener = nil
        roomPose = nil
        windowPose = nil
        screenPose = nil
        status = "Closed"
    }

    fileprivate func noteScreenAttached(_ attached: Bool) {
        if screenAttached != attached { screenAttached = attached }
    }

    fileprivate func noteScreenTap() { screenTaps += 1 }

    // MARK: Per-frame placement

    /// The device's pose now, for the HUD's per-frame follow.
    func hudDevicePose() -> simd_float4x4? {
        guard let tracking = worldTracking, tracking.state == .running,
              let anchor = tracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()),
              anchor.isTracked else { return nil }
        return anchor.originFromAnchorTransform
    }

    private func update(dt: Float) {
        guard let tracking = worldTracking, tracking.state == .running,
              let anchor = tracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()),
              anchor.isTracked else { return }
        let head = anchor.originFromAnchorTransform
        if headPose == nil { status = "Tracking" }
        headPose = head
        if mode == .bigScreen, screenPose == nil { placeScreen(facing: head) }

        if headLocked {
            // The head's own pose: −z where it looks, so the room turns with it.
            roomPose = head
            listener = head.columns.3.xyz
            return
        }
        let position = head.columns.3.xyz
        if mode == .hud {
            // Keep the film's object stage facing the HUD as the wearer moves.
            let direction = simd_make_float3(head * SIMD4(hudOffset, 0))
            listener = position
            roomPose = Self.pose(at: position, forward: direction, fallback: -head.columns.2.xyz)
            return
        }
        let k = 1 - expf(-max(dt, 0) / Self.followSeconds)
        let centre = listener.map { $0 + (position - $0) * k } ?? position
        listener = centre
        let target = mode == .bigScreen ? screenPose?.columns.3.xyz : windowPose?.columns.3.xyz
        let fallback = -head.columns.2.xyz
        roomPose = Self.pose(at: centre, forward: target.map { $0 - centre } ?? fallback, fallback: fallback)
    }

    private func placeScreen(facing head: simd_float4x4) {
        let position = head.columns.3.xyz
        guard let forward = Self.horizontal(-head.columns.2.xyz) else { return }
        screenPose = Self.pose(at: position + forward * screenDistance, forward: forward, fallback: forward)
        logger.info("Cinema: screen placed \(self.screenDistance, format: .fixed(precision: 1), privacy: .public) m ahead, \(self.screenWidth, format: .fixed(precision: 1), privacy: .public) m wide")
    }

    /// A changed distance moves the screen along its own heading from the listener.
    private func refitScreen() {
        guard let screenPose, let centre = listener else { return }
        let forward = Self.horizontal(-screenPose.columns.2.xyz) ?? SIMD3(0, 0, -1)
        var position = centre + forward * screenDistance
        position.y = screenPose.columns.3.y
        self.screenPose = Self.pose(at: position, forward: forward, fallback: forward)
    }

    /// A pose at `position` whose −z points along `forward` (level), +y up.
    private static func pose(at position: SIMD3<Float>, forward: SIMD3<Float>, fallback: SIMD3<Float>) -> simd_float4x4 {
        let f = horizontal(forward) ?? horizontal(fallback) ?? SIMD3(0, 0, -1)
        let yaw = atan2f(-f.x, -f.z)
        var pose = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
        pose.columns.3 = SIMD4(position, 1)
        return pose
    }

    private static func horizontal(_ v: SIMD3<Float>) -> SIMD3<Float>? {
        let flat = SIMD3(v.x, 0, v.z)
        let length = simd_length(flat)
        return length > 1e-3 ? flat / length : nil
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}

// MARK: - HUD follow

/// The HUD hangs from a smoothed copy of the head, placed in the world every
/// frame, rather than from `AnchorEntity(.head)`: rigidly head-locked content
/// shakes with every step, and the lag lets the picture settle instead. The lag
/// is bounded (`HUDFraming.lagLimits`): however fast the wearer turns or moves,
/// the smoothed head stays close enough to the real one for the picture to
/// stay in view.
@MainActor
final class CinemaHUDFollow {
    static let shared = CinemaHUDFollow()

    /// Time constants of the follow, in seconds, per axis: horizontal stays
    /// tight so walking doesn't leave the picture behind, while the vertical
    /// and rotation take out the bob and the jitter of each step.
    var rotationSeconds: Float = 0.15
    var verticalSeconds: Float = 0.2
    var horizontalSeconds: Float = 0.08

    /// The smoothed head; the screen hangs from it at `hudOffset`.
    let head = Entity()
    private var subscription: (any Cancellable)?
    private weak var subscribedScene: RealityKit.Scene?
    private var position: SIMD3<Float>?
    private var rotation: simd_quatf?

    var hasPose: Bool { position != nil }

    init() { head.name = "cinema-hud-follow" }

    /// Parents the smoothed head and steps it on every scene update. Screens
    /// a previous space left on the shared head go, so only `screen` shows.
    func attach(to root: Entity, keeping screen: Entity) {
        if head.parent !== root { root.addChild(head) }
        for child in Array(head.children) where child !== screen { child.removeFromParent() }
        guard let scene = root.scene, scene !== subscribedScene else { return }
        subscription?.cancel()
        subscribedScene = scene
        subscription = scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated { self?.step(dt: Float(event.deltaTime)) }
        }
    }

    func step(dt: Float) {
        let cinema = Cinema.shared
        guard cinema.mode == .hud else {
            position = nil
            rotation = nil
            return
        }
        guard let pose = cinema.hudDevicePose() else { return }
        let targetPosition = pose.columns.3.xyz
        let targetRotation = simd_quatf(pose)
        guard var smoothedPosition = position, var smoothedRotation = rotation else {
            position = targetPosition
            rotation = targetRotation
            head.transform = Transform(rotation: targetRotation, translation: targetPosition)
            return
        }
        func blend(_ seconds: Float) -> Float {
            seconds > 0 ? 1 - expf(-max(dt, 0) / seconds) : 1
        }
        let horizontal = blend(horizontalSeconds)
        smoothedPosition.x += (targetPosition.x - smoothedPosition.x) * horizontal
        smoothedPosition.z += (targetPosition.z - smoothedPosition.z) * horizontal
        smoothedPosition.y += (targetPosition.y - smoothedPosition.y) * blend(verticalSeconds)
        smoothedRotation = simd_slerp(smoothedRotation, targetRotation, blend(rotationSeconds))
        // The smoothing may soften a movement but never leave the picture
        // behind it: the lag is held to what the picture leaves free of the view.
        let limits = cinema.hudLagLimits
        smoothedPosition = HUDFraming.limit(smoothedPosition, near: targetPosition, by: limits.position)
        smoothedRotation = HUDFraming.limit(smoothedRotation, toward: targetRotation, by: limits.rotation)
        position = smoothedPosition
        rotation = smoothedRotation
        head.transform = Transform(rotation: smoothedRotation, translation: smoothedPosition)
    }
}

// MARK: - The space

/// The controls and the window chrome are separate attachments so the
/// grab bar can sit beside the close button without overlapping the strip.
private struct CinemaHUDControls: View {
    @Bindable private var cinema = Cinema.shared
    let presentation: RAVEImmersivePlayerPresentation

    var body: some View {
        Group { if let controls = cinema.hudControlsView { controls } }
            .environment(\.raveImmersivePlayerPresentation, presentation)
            .coordinateSpace(name: RAVEImmersivePlayerPresentation.coordinateSpace)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { presentation.controlsSize = $0 }
    }
}

private struct CinemaHUDClose: View {
    let closePlayer: () -> Void
    var body: some View {
        Button("Close Player", systemImage: "xmark", action: closePlayer)
            .labelStyle(.iconOnly).buttonStyle(.bordered).buttonBorderShape(.circle)
    }
}

private struct CinemaHUDUtilities: View {
    let returnToWindow: () -> Void
    @Bindable private var cinema = Cinema.shared
    var body: some View {
        HStack(spacing: 12) {
            Button("Recenter", systemImage: "scope") { cinema.recenterHUD() }
            Button("Window", systemImage: "macwindow", action: returnToWindow)
        }
        .labelStyle(.iconOnly).buttonStyle(.bordered).buttonBorderShape(.circle)
    }
}

private struct CinemaHUDMenuAttachment: View {
    let presentation: RAVEImmersivePlayerPresentation

    var body: some View {
        presentation.content
            .frame(width: 360)
            .fixedSize(horizontal: false, vertical: true)
            .glassBackgroundEffect()
    }
}

/// The cinema space's content: the film's object-audio stage and, for Big
/// Screen, the owner's picture on a screen.
struct CinemaSpaceView: View {
    @Environment(\.openImmersiveSpace) private var open
    @Environment(\.dismissImmersiveSpace) private var dismiss
    @Environment(AppModel.self) private var appModel
    @Bindable private var cinema = Cinema.shared
    private let session = FilmSession.shared
    @State private var screen = Entity()
    @State private var sceneRoot = Entity()
    @State private var headAnchor = AnchorEntity(.head)
    @State private var hudHandle = Entity()
    @State private var hudControls = Entity()
    @State private var hudClose = Entity()
    @State private var hudUtilities = Entity()
    @State private var presentationEntity = Entity()
    @State private var presentation = RAVEImmersivePlayerPresentation()
    @State private var chromeOpacity: Float = 0
    @State private var chromeLastUpdate = CACurrentMediaTime()
    @State private var leftEdge = Entity()
    @State private var rightEdge = Entity()
    @State private var dragStart: SIMD3<Float>?
    @State private var resizeStart: Float?
    /// A video window's picture: a `VideoPlayerComponent` on its player.
    @State private var playerPicture = Entity()
    @State private var playerPictureSource: ObjectIdentifier?
    /// The stereo engine whose plane is on the screen, given back when it isn't.
    @State private var stereoPictureEngine: Pseudo3DStereoEngine?
    /// The subtitles over the picture, a view attachment.
    @State private var subtitles = Entity()
    @State private var subtitlesSource: ObjectIdentifier?
    /// The attachment's size in points; its aspect follows the picture's.
    private static let subtitleWidthPoints: CGFloat = 1600

    var body: some View {
        ZStack {
            if cinema.owner == .film {
                FilmStageView(player: session.player, roomPose: { Cinema.shared.roomPose })
            }
            RealityView { content in
                screen.name = "cinema-screen"
                playerPicture.name = "cinema-player-picture"
                subtitles.name = "cinema-subtitles"
                content.add(sceneRoot)
                sceneRoot.addChild(screen)
                content.add(headAnchor)
                hudHandle.components.set(ModelComponent(mesh: .generateBox(width: 0.18, height: 0.014, depth: 0.008, cornerRadius: 0.007), materials: [UnlitMaterial(color: .white)]))
                hudHandle.components.set(CollisionComponent(shapes: [.generateBox(width: 0.28, height: 0.07, depth: 0.04)]))
                hudHandle.components.set(InputTargetComponent())
                for edge in [leftEdge, rightEdge] {
                    edge.components.set(CollisionComponent(shapes: [.generateBox(width: 0.08, height: 0.6, depth: 0.05)]))
                    edge.components.set(InputTargetComponent())
                    edge.components.set(HoverEffectComponent())
                }
                hudControls.components.set(ViewAttachmentComponent(rootView: CinemaHUDControls(presentation: presentation)))
                hudClose.components.set(ViewAttachmentComponent(rootView: CinemaHUDClose {
                    guard let owner = cinema.owner else { return }
                    cinema.hudCloseAction?()
                    Task { await cinema.release(owner, dismiss: dismiss) }
                }))
                hudUtilities.components.set(ViewAttachmentComponent(rootView: CinemaHUDUtilities {
                    guard let owner = cinema.owner else { return }
                    Task { await cinema.setMode(.window, for: owner, open: open, dismiss: dismiss) }
                }))
            }
            .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { value in
                if value.entity === playerPicture || value.entity === session.player.video.videoEntity
                    || (stereoPictureEngine != nil && value.entity === stereoPictureEngine?.videoEntity) {
                    cinema.noteScreenTap()
                }
            })
            .simultaneousGesture(DragGesture().targetedToEntity(hudHandle)
                .onChanged { value in
                    if dragStart == nil { dragStart = cinema.hudOffset }
                    let movement = value.convert(value.translation3D, from: .local, to: screen.parent ?? headAnchor)
                    if let dragStart {
                        let candidate = dragStart + movement
                        cinema.moveHUD(to: candidate)
                    }
                }
                .onEnded { _ in dragStart = nil })
            .simultaneousGesture(DragGesture().targetedToAnyEntity()
                .onChanged { value in
                    guard value.entity === leftEdge || value.entity === rightEdge else { return }
                    // From the width drawn, which a close picture holds below the one asked for.
                    if resizeStart == nil { resizeStart = cinema.pictureWidth }
                    let movement = value.convert(value.translation3D, from: .local, to: screen)
                    let sign: Float = value.entity === rightEdge ? 1 : -1
                    if let resizeStart { cinema.hudWidth = min(4, max(0.4, resizeStart + sign * 2 * movement.x)) }
                }
                .onEnded { _ in resizeStart = nil })
        }
        .preferredSurroundingsEffect(cinema.mode == .bigScreen && cinema.dimsSurroundings ? .systemDark : nil)
        .onAppear { cinema.spaceAppeared() }
        .onChange(of: presentation.isPresented) { _, shown in
            AppLogger.videoWindow.info("HUD menu requested: \(shown, privacy: .public)")
        }
        .onDisappear {
            presentation.dismiss()
            cinema.spaceDisappeared()
        }
        // Placed in a loop rather than RealityView's update: the window's
        // plane view may still lay the entity out once after it moves here.
        .task {
            while !Task.isCancelled {
                placeScreen()
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func placeScreen() {
        let filmPicture = session.player.video.videoEntity
        // A film picture left here by a previous owner goes back to its
        // window, which re-adds it once it shows it again.
        if cinema.owner != .film || !cinema.mode.showsPicture, filmPicture.parent === screen {
            filmPicture.removeFromParent()
        }
        // A video window between players keeps the last one's picture.
        if cinema.owner == .film || cinema.owner == nil || !cinema.mode.showsPicture {
            releasePlayerPicture()
        }
        // A stereo plane goes back to its window as soon as it isn't shown
        // here, or another engine (or the flat player) takes over.
        if stereoPictureEngine != nil,
           !cinema.mode.showsPicture || cinema.owner == .film || cinema.owner == nil
            || cinema.screenStereo !== stereoPictureEngine {
            releaseStereoPicture()
        }
        guard cinema.mode.showsPicture, let owner = cinema.owner else {
            hudHandle.removeFromParent()
            hudControls.removeFromParent()
            hudClose.removeFromParent()
            hudUtilities.removeFromParent()
            presentationEntity.components.remove(ViewAttachmentComponent.self)
            presentationEntity.removeFromParent()
            presentation.dismiss()
            chromeOpacity = 0
            leftEdge.removeFromParent()
            rightEdge.removeFromParent()
            releaseSubtitles()
            cinema.noteScreenAttached(false)
            return
        }
        if cinema.mode == .hud {
            if !cinema.headLocked, let player = cinema.screenPlayer,
               !(player.intendedSpatialAudioExperience is AutomaticSpatialAudio) {
                player.intendedSpatialAudioExperience = AutomaticSpatialAudio.automatic
            }
            // Until the follow has its first pose, the head anchor holds the screen.
            let follow = CinemaHUDFollow.shared
            follow.attach(to: sceneRoot, keeping: screen)
            let parent = follow.hasPose ? follow.head : headAnchor
            if screen.parent !== parent { parent.addChild(screen) }
            let direction = simd_normalize(-cinema.hudOffset)
            screen.transform = Transform(rotation: simd_quatf(from: SIMD3<Float>(0, 0, 1), to: direction), translation: cinema.hudOffset)
            if hudHandle.parent !== screen { screen.addChild(hudHandle) }
            if hudControls.parent !== screen { screen.addChild(hudControls) }
            if hudClose.parent !== screen { screen.addChild(hudClose) }
            if hudUtilities.parent !== screen { screen.addChild(hudUtilities) }
            if presentationEntity.parent !== screen { screen.addChild(presentationEntity) }
            if leftEdge.parent !== screen { screen.addChild(leftEdge) }
            if rightEdge.parent !== screen { screen.addChild(rightEdge) }
        } else {
            guard let pose = cinema.screenPose else { cinema.noteScreenAttached(false); return }
            if screen.parent !== sceneRoot {
                screen.removeFromParent()
                // Reparent through the scene root retained by the RealityView.
                sceneRoot.addChild(screen)
            }
            hudHandle.removeFromParent()
            hudControls.removeFromParent()
            hudClose.removeFromParent()
            hudUtilities.removeFromParent()
            presentationEntity.components.remove(ViewAttachmentComponent.self)
            presentationEntity.removeFromParent()
            presentation.dismiss()
            chromeOpacity = 0
            leftEdge.removeFromParent()
            rightEdge.removeFromParent()
            screen.setTransformMatrix(pose, relativeTo: nil)
        }

        let picture: Entity
        let aspect: Float
        switch owner {
        case .film:
            let video = session.player.video
            picture = filmPicture
            aspect = video.pictureAspect ?? 16 / 9
            video.pictureAttached = true
        case .video:
            if let engine = cinema.screenStereo, let plane = engine.lendPicture() {
                if stereoPictureEngine !== engine {
                    stereoPictureEngine = engine
                    // The flat player's plane would sit behind it.
                    releasePlayerPicture()
                    AppLogger.videoWindow.info("Cinema: stereo picture on the big screen")
                }
                picture = plane
                aspect = engine.pictureAspect ?? lastAspect(of: plane)
                engine.noteLentPlaneWidth(cinema.pictureWidth)
                break
            }
            if let player = cinema.screenPlayer, playerPictureSource != ObjectIdentifier(player) {
                playerPicture.components.set(VideoPlayerComponent(avPlayer: player))
                playerPictureSource = ObjectIdentifier(player)
                AppLogger.videoWindow.info("Cinema: video player on the big screen")
            }
            // Nothing lent yet (the space opened before the player resolved).
            guard playerPictureSource != nil else {
                cinema.noteScreenAttached(false)
                return
            }
            picture = playerPicture
            let size = cinema.screenPlayer?.currentItem?.presentationSize ?? .zero
            aspect = size.width > 0 && size.height > 0 ? Float(size.width / size.height) : lastAspect(of: picture)
        }
        if picture.parent !== screen {
            screen.addChild(picture)
            AppLogger.filmPlayer.info("Cinema: picture moved to the big screen")
        }
        // The framing needs the picture's shape; a new one (or a resize) may
        // leave the HUD's offset outside the view, so it is pulled back first.
        if cinema.mode == .hud {
            cinema.hudAspect = max(aspect, 0.1)
            cinema.refitHUD()
        }
        // The video component's mesh is aspect × 1 m, so its scale is its height.
        let height = cinema.pictureWidth / max(aspect, 0.1)
        let controlsVisible = presentation.isPresented || (owner == .film ? cinema.hudFilmChromeVisible : !(cinema.hudVideoModel?.isUIHidden ?? false))
        let now = CACurrentMediaTime()
        let step = Float(min(max(now - chromeLastUpdate, 0), 0.1)) / 0.22
        chromeLastUpdate = now
        chromeOpacity = controlsVisible ? min(1, chromeOpacity + step) : max(0, chromeOpacity - step)
        let slide = (1 - chromeOpacity) * 0.04
        if controlsVisible { hudControls.isEnabled = true; hudClose.isEnabled = true; hudUtilities.isEnabled = true }
        if cinema.mode == .hud, hudControls.isEnabled,
           let bounds = hudControls.components[ViewAttachmentComponent.self]?.bounds,
           bounds.extents.x > 1e-4 {
            let scale = cinema.pictureWidth / bounds.extents.x
            let controlsHeight = bounds.extents.y * scale
            hudControls.scale = SIMD3(repeating: scale)
            hudControls.position = SIMD3(0, -height / 2 - 0.05 - controlsHeight / 2 - slide, 0.02)
            let chromeY = -height / 2 - 0.05 - controlsHeight - 0.12 - slide
            hudHandle.position = SIMD3(0, chromeY, 0.02)
            hudClose.position = SIMD3(-0.18, chromeY, 0.025)
            hudUtilities.position = SIMD3(0.25, chromeY, 0.025)
        }
        if cinema.mode == .hud, hudClose.isEnabled, hudUtilities.isEnabled {
            if let bounds = hudClose.components[ViewAttachmentComponent.self]?.bounds, bounds.extents.x > 1e-4 {
                hudClose.scale = SIMD3(repeating: 0.085 / bounds.extents.x)
            }
            if let bounds = hudUtilities.components[ViewAttachmentComponent.self]?.bounds, bounds.extents.x > 1e-4 {
                hudUtilities.scale = SIMD3(repeating: 0.19 / bounds.extents.x)
            }
        }
        if cinema.mode == .hud {
            reconcilePresentation()
            if let bounds = presentationEntity.components[ViewAttachmentComponent.self]?.bounds,
               let controlsBounds = hudControls.components[ViewAttachmentComponent.self]?.bounds,
               let source = presentation.sourceFrame, presentation.controlsSize.width > 0 {
                let scale = hudControls.scale.x
                let pointScale = controlsBounds.extents.x * scale / Float(presentation.controlsSize.width)
                let x = Float(source.midX - presentation.controlsSize.width / 2) * pointScale
                let y = hudControls.position.y + Float(presentation.controlsSize.height / 2 - source.minY) * pointScale
                presentationEntity.scale = SIMD3(repeating: scale)
                presentationEntity.position = SIMD3(x, y + 0.015 + bounds.extents.y * scale / 2, 0.1)
            }
        }
        leftEdge.position = SIMD3(-cinema.pictureWidth / 2, 0, 0.02)
        rightEdge.position = SIMD3(cinema.pictureWidth / 2, 0, 0.02)
        leftEdge.scale.y = max(height / 0.6, 0.2)
        rightEdge.scale.y = leftEdge.scale.y
        for entity in [hudControls, hudClose, hudUtilities, hudHandle] {
            entity.components.set(OpacityComponent(opacity: chromeOpacity))
            entity.isEnabled = chromeOpacity > 0
        }
        leftEdge.isEnabled = controlsVisible
        rightEdge.isEnabled = controlsVisible
        let transform = Transform(scale: SIMD3(repeating: height))
        if picture.transform != transform { picture.transform = transform }
        if picture.components[OpacityComponent.self]?.opacity != 1 {
            picture.components.set(OpacityComponent(opacity: 1))
        }
        if picture.components[CollisionComponent.self] == nil {
            let box = ShapeResource.generateBox(width: aspect, height: 1, depth: 0.001)
            picture.components.set(CollisionComponent(shapes: [box], isStatic: true))
        }
        if picture.components[InputTargetComponent.self]?.isEnabled != true {
            picture.components.set(InputTargetComponent())
        }
        placeSubtitles(aspect: aspect)
        cinema.noteScreenAttached(cinema.mode != .hud || headAnchor.isAnchored)
    }

    /// Immersive spaces reject modal presentations, including ones created
    /// by PresentationComponent. Draw the menu as a head-relative attachment.
    private func reconcilePresentation() {
        guard presentation.isPresented else {
            presentationEntity.components.remove(ViewAttachmentComponent.self)
            return
        }
        if presentationEntity.components[ViewAttachmentComponent.self] == nil {
            AppLogger.videoWindow.info("HUD menu: installing view attachment")
            presentationEntity.components.set(ViewAttachmentComponent(
                rootView: CinemaHUDMenuAttachment(presentation: presentation).environment(appModel)
            ))
        }
    }

    /// The aspect the picture was last scaled for, from its collision box.
    private func lastAspect(of picture: Entity) -> Float {
        guard let shape = picture.components[CollisionComponent.self]?.shapes.first else { return 16 / 9 }
        let extents = shape.bounds.extents
        return extents.y > 0 ? extents.x / extents.y : 16 / 9
    }

    /// The owner's subtitles over the picture, as large as the screen.
    private func placeSubtitles(aspect: Float) {
        guard let source = cinema.screenSubtitles else {
            releaseSubtitles()
            return
        }
        let height = Self.subtitleWidthPoints / CGFloat(max(aspect, 0.1))
        if subtitlesSource != ObjectIdentifier(source.controller) {
            let time = source.time
            subtitles.components.set(ViewAttachmentComponent(rootView:
                SubtitleOverlay(controller: source.controller, pictureAspect: CGFloat(aspect), filmTime: time)
                    .frame(width: Self.subtitleWidthPoints, height: height)))
            subtitlesSource = ObjectIdentifier(source.controller)
        }
        if subtitles.parent !== screen { screen.addChild(subtitles) }
        // Just in front of the picture, scaled from the attachment's own
        // measured width to the screen's.
        guard let bounds = subtitles.components[ViewAttachmentComponent.self]?.bounds,
              bounds.extents.x > 1e-4 else { return }
        let scale = cinema.pictureWidth / bounds.extents.x
        let transform = Transform(scale: SIMD3(repeating: scale), translation: SIMD3(0, 0, 0.05))
        if subtitles.transform != transform { subtitles.transform = transform }
    }

    private func releaseSubtitles() {
        guard subtitlesSource != nil else { return }
        subtitles.components.remove(ViewAttachmentComponent.self)
        subtitles.removeFromParent()
        subtitlesSource = nil
    }

    private func releaseStereoPicture() {
        guard let engine = stereoPictureEngine else { return }
        stereoPictureEngine = nil
        engine.reclaimPicture()
    }

    private func releasePlayerPicture() {
        guard playerPictureSource != nil else { return }
        playerPicture.components.remove(VideoPlayerComponent.self)
        playerPicture.removeFromParent()
        playerPictureSource = nil
    }
}

// MARK: - The players' side

/// An entity at the film window's centre whose pose in the cinema space
/// tells the stage where the window is.
struct FilmWindowMarker: View {
    private let cinema = Cinema.shared
    @State private var marker = Entity()

    var body: some View {
        RealityView { content in
            marker.name = "film-window-marker"
            content.add(marker)
        }
        .task(id: cinema.hostsFilmSound) {
            guard cinema.hostsFilmSound else { return }
            while !Task.isCancelled {
                if let pose = marker.transformMatrix(relativeTo: .immersiveSpace) { cinema.windowPose = pose }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

/// What a player window shows while its picture is on the big screen.
struct CinemaBigScreenCard: View {
    let owner: CinemaOwner
    let onTap: () -> Void
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles.tv").font(.system(size: 44))
            Text(Cinema.shared.screenAttached ? "Playing in \(Cinema.shared.mode.title)" : "Opening \(Cinema.shared.mode.title)…").font(.title2)
            HStack(spacing: 12) {
                Button("Place in Front of Me", systemImage: "scope") {
                    if Cinema.shared.mode == .hud { Cinema.shared.recenterHUD() }
                    else { Cinema.shared.placeScreenInFront() }
                }
                Button("Back to Window", systemImage: "macwindow") {
                    Task { await Cinema.shared.setMode(.window, for: owner, open: openImmersiveSpace, dismiss: dismissImmersiveSpace) }
                }
            }
        }
        .padding(32)
        .glassBackgroundEffect()
        .contentShape(.rect)
        .onTapGesture(perform: onTap)
    }
}

/// The control strip's Cinema button: the owner's modes and head-locked sound.
struct CinemaButton: View {
    let owner: CinemaOwner
    /// Big Screen can be had (a video that can reach the AVFoundation renderer).
    var bigScreenAvailable = true
    /// Bumped by the host to close the popover (a tap on the picture).
    var dismissal = 0
    var onOpenChanged: (Bool) -> Void = { _ in }
    private let cinema = Cinema.shared
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    private var badge: String? {
        let mode = cinema.mode(for: owner)
        if mode != .window { return mode.title }
        return cinema.headLocked ? "Head" : nil
    }

    var body: some View {
        PlayerChoiceMenu(title: "Cinema", systemImage: "sparkles.tv", badge: badge,
                         badgeIsActive: cinema.mode(for: owner) != .window,
                         help: "Big screen and how the sound is placed",
                         dismissal: dismissal,
                         onOpenChanged: onOpenChanged) { close in
            ForEach(owner.modes) { mode in
                Button {
                    close()
                    Task { await cinema.setMode(mode, for: owner, open: openImmersiveSpace, dismiss: dismissImmersiveSpace) }
                } label: {
                    PlayerChoiceRow(mode.title, isChecked: mode == cinema.mode(for: owner))
                }
                .disabled(mode.showsPicture && !bigScreenAvailable)
            }
            Divider()
            Button {
                close()
                Task {
                    await cinema.setHeadLocked(!cinema.headLocked, for: owner,
                                               open: openImmersiveSpace, dismiss: dismissImmersiveSpace)
                }
            } label: {
                PlayerChoiceRow("Head-Locked Sound", isChecked: cinema.headLocked)
            }
            .help("The sound turns with your head instead of staying in the room")
        }
        .accessibilityIdentifier("player.cinema")
    }
}

/// A video window's half of the cinema: Big Screen needs the AVFoundation
/// renderer and no in-window 3D, and the window's player goes to the screen.
struct CinemaVideoWindowHook: ViewModifier {
    let windowModel: VideoWindowModel
    let hudControls: AnyView
    let closePlayer: @MainActor () -> Void
    private var cinema: Cinema { .shared }
    private var owner: CinemaOwner { .video(ObjectIdentifier(windowModel)) }
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(SceneDelegate.self) private var sceneDelegate: SceneDelegate?

    private var onBigScreen: Bool { cinema.mode(for: owner).showsPicture }

    func body(content: Content) -> some View {
        content
            .onChange(of: onBigScreen, initial: true) { _, on in
                windowModel.holdsBigScreen = on
                if on { prepare() }
            }
            .onChange(of: windowModel.playbackRenderer) {
                if onBigScreen { prepare() }
            }
            .onChange(of: windowModel.nativePlayerGeneration) { lendPlayer(); routeAudio() }
            .onChange(of: cinema.mode(for: owner), initial: true) { _, _ in routeAudio() }
            // AI 3D and live 3D lend their plane to the screen; the immersive
            // player has its own space, so picking it ends Big Screen.
            .onChange(of: windowModel.usesImmersiveStereo) { _, immersive in
                guard immersive, onBigScreen else { return }
                Task { await cinema.setMode(.window, for: owner, open: openImmersiveSpace, dismiss: dismissImmersiveSpace) }
            }
            .onChange(of: windowModel.showsStereoPicture) { if onBigScreen { lendPlayer() } }
            .onChange(of: windowModel.stereoEngine.map(ObjectIdentifier.init)) { if onBigScreen { lendPlayer() } }
            .onChange(of: cinema.screenTaps) {
                if cinema.owner == owner { windowModel.toggleUIVisibility() }
            }
            .onDisappear {
                windowModel.holdsBigScreen = false
                let owner = owner
                Task { await Cinema.shared.release(owner, dismiss: dismissImmersiveSpace) }
            }
    }

    private func prepare() {
        cinema.hudVideoModel = windowModel
        cinema.hudControlsView = hudControls
        cinema.hudCloseAction = closePlayer
        // The immersive player needs the space for itself; live 3D and AI 3D
        // come along (their plane moves to the screen).
        if windowModel.usesImmersiveStereo { windowModel.stereoscopicOverride = false }
        if windowModel.playbackRenderer == .webKit,
           !windowModel.switchToTranscodedStream(reason: "The immersive screen needs the AVFoundation renderer") {
            let owner = owner
            Task {
                await cinema.fail("This video can't play on the immersive screen: the server has no transcode this device can decode.",
                                  for: owner, dismiss: dismissImmersiveSpace)
            }
            windowModel.showQualityNotice("This video can't play on the immersive screen.")
            return
        }
        lendPlayer()
    }

    private func lendPlayer() {
        guard cinema.owner == owner else { return }
        let stereo = windowModel.showsStereoPicture ? windowModel.stereoEngine : nil
        cinema.setScreenStereo(stereo, for: owner)
        if stereo == nil {
            cinema.setScreenPlayer(windowModel.playbackRenderer == .nativeMetal ? windowModel.nativePlayer : nil, for: owner)
        }
        // A stereo picture draws its subtitles into itself when set to.
        let model = windowModel
        let drawnInPicture = stereo != nil
            && (UserDefaults.standard.string(forKey: StereoSubtitleStyle.key)
                .flatMap(StereoSubtitleStyle.init(rawValue:)) ?? .inPicture) == .inPicture
        cinema.setSubtitles(drawnInPicture ? nil
                            : CinemaSubtitles(controller: model.subtitles, time: { [weak model] in model?.currentTime ?? 0 }),
                            for: owner)
    }

    private func routeAudio() {
        guard let player = windowModel.nativePlayer, let item = player.currentItem,
              let asset = item.asset as? AVURLAsset else { return }
        if cinema.mode(for: owner) == .hud {
            // Let AVPlayer follow its VideoPlayerComponent in the immersive scene
            // instead of the window whose scene was named by the Metal renderer.
            item.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
            player.intendedSpatialAudioExperience = cinema.headLocked
                ? .fixed(soundStageSize: .automatic) : AutomaticSpatialAudio.automatic
        } else {
            let identifier = sceneDelegate?.spatialAudioSceneIdentifier
            item.applySpatialAudioPolicy(sceneIdentifier: identifier)
            player.applySpatialAudioPolicy(for: asset, sceneIdentifier: identifier)
        }
    }
}

/// Sound and Picture's Cinema section.
struct CinemaSettings: View {
    @Bindable private var cinema = Cinema.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "Screen distance: %.0f m", cinema.screenDistance)).font(.caption)
            Slider(value: $cinema.screenDistance, in: 5 ... 40, step: 1)
        }
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "Screen size: %.0f° (%.1f m wide)", cinema.screenWidthDegrees, cinema.screenWidth))
                .font(.caption)
            Slider(value: $cinema.screenWidthDegrees, in: 30 ... 100, step: 1)
        }
        Toggle("Dim Surroundings", isOn: $cinema.dimsSurroundings)
        Text("Cinema: \(cinema.status)").font(.caption).foregroundStyle(.secondary)
    }
}
#endif
