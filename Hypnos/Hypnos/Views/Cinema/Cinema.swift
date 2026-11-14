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
 - **Head-Locked Sound** (`headLockedMode`, one setting for every player): the
   sound turns with the head instead of staying in the room. `always` makes a
   video window's 5.1/7.1 `.fixed` spatial audio and leaves stereo
   unspatialized (`RAVEMediaPolicy.headLockedSound`, which every playing
   `AVPlayer` follows). `byLayout` (Smart Activation) decides per player from
   its probed audio: mono and stereo play head-locked, which keeps their full
   quality, and 5.1/7.1 stays head-tracked, which keeps its spatial features.
   The film's object room is set to the head's pose every frame, which needs
   the space, so a film with `always` opens it even in Window mode; under
   `byLayout` a film is surround, so its room stays put.

 The space asks to coexist with a system environment
 (`immersiveEnvironmentBehavior(.coexist)`, visionOS 26), so Mount Hood and
 the rest stay up around the screen. Our own windows stay visible in our
 mixed space; other apps' windows hide while it is open. An app has one
 immersive space at a time, so opening the cinema closes Spatial 3D first.

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

extension RAVEHeadLockedSound {
    var title: String {
        switch self {
        case .off: "Off"
        case .always: "Always"
        case .byLayout: "By Audio Layout"
        }
    }

    var help: String {
        switch self {
        case .off: "The sound stays where the video is"
        case .always: "The sound turns with your head instead of staying in the room"
        case .byLayout: "Stereo and mono turn with your head and keep full quality; surround stays in the room, with its spatial features"
        }
    }
}

/// What the screen's subtitles come from: the owner's controller and clock.
struct CinemaSubtitles {
    let controller: SubtitleController
    let time: @MainActor () -> Double
}

/// What an owner's prompt (skip button, notices) shows, so it is handed to
/// the HUD again only when that changes.
struct CinemaPromptKey: Equatable {
    var inHUD: Bool
    var notices: [String]
    var segment: LibraryMediaSegment?
    var undo: UUID?
    /// The rate-it bar after an undo, with the vote on it.
    var feedback: String? = nil
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

/// Whoever owns the immersive space the cinema's content lives in, when it is not this app's own:
/// Nexus's shared space, where joining and leaving go through a broker, and a bare
/// `dismissImmersiveSpace()` would close every module's space.
@MainActor
protocol CinemaSpaceHosting: AnyObject {
    /// Puts the cinema's content in the space; true once it is there.
    func joinCinemaSpace() async -> Bool
    /// Takes it out; the space closes if nobody else is in it.
    func leaveCinemaSpace() async
}

@MainActor
@Observable
final class Cinema {
    static let shared = Cinema()
    static let spaceID = "CinemaSpace"

    /// Set by Nexus's module. Nil in this app's own build, where the cinema opens and closes its
    /// own `ImmersiveSpace` through the SwiftUI actions its callers pass.
    @ObservationIgnored var spaceHost: CinemaSpaceHosting?
    /// The actions of the space's own view while it is up, for the HUD's buttons, which are
    /// entities in the space and have no environment to read them from.
    @ObservationIgnored fileprivate var viewActions: (open: OpenImmersiveSpaceAction, dismiss: DismissImmersiveSpaceAction)?

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
    var hudOffset = Cinema.hudHomeOffset
    var hudWidth: Float = Cinema.hudHomeWidth

    /// Where the HUD opens and Recenter takes it, picture-in-picture style:
    /// a small picture 1 m away, low in the right of the view (18° right,
    /// 12° down, 31° wide). It used to open 2 m ahead and 55° wide, a second
    /// big screen that had to be shrunk and pulled in by hand every time
    /// (user, 2026-11-05). Where the wearer then puts it is kept (`save`).
    static let hudHomeWidth: Float = 0.55
    static let hudHomeOffset: SIMD3<Float> = {
        let azimuth: Float = 18 * .pi / 180, elevation: Float = -12 * .pi / 180
        return SIMD3(sinf(azimuth) * cosf(elevation), sinf(elevation), -cosf(azimuth) * cosf(elevation))
    }()
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
        hudOffset = Self.hudHomeOffset
        hudWidth = Self.hudHomeWidth
        refitHUD()
        save()
    }

    /// The wearer let go of the HUD after moving or resizing it: it opens there next time.
    func hudPlacementSettled() { save() }

    /// The skip button and notices the owner wants shown with the HUD's
    /// picture, which its window then doesn't show.
    private(set) var hudPrompt: AnyView?

    func setHUDPrompt(_ prompt: AnyView?, for owner: CinemaOwner) {
        guard self.owner == owner else { return }
        hudPrompt = prompt
    }

    /// How far the HUD's smoothed head may lag the real one right now.
    var hudLagLimits: (rotation: Float, position: Float) {
        HUDFraming.lagLimits(offset: hudOffset, requestedWidth: hudWidth, aspect: hudAspect,
                             stabilization: hudStabilization)
    }

    /// How much of the follow's range of motion the HUD keeps, 0 ... 1. Less
    /// holds the picture closer to the head (0 locks it); persisted.
    var hudStabilization: Float = 1 {
        didSet {
            let clamped = hudStabilization.isFinite ? min(1, max(0, hudStabilization)) : 1
            if clamped != hudStabilization { hudStabilization = clamped; return }
            save()
        }
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

    /// Where the sound sits (see the header): the one setting for every player.
    private(set) var headLockedMode = RAVEHeadLockedSound.off
    /// Every player's sound turns with the head. `.byLayout` is not this: it
    /// locks stereo and mono players only, never the film (object audio is
    /// surround, which keeps its spatial features), so what the film's room
    /// and the space it needs follow is this alone.
    var headLocked: Bool { headLockedMode == .always }

    /// Whether `player`'s sound turns with the head: `.byLayout` asks what the
    /// spatial-audio policy found in its audio (stereo until it knows).
    func headLocked(for player: AVPlayer) -> Bool {
        headLockedMode.locks(multichannel: player.spatialAudioIsMultichannel)
    }
    /// Metres from the head to the screen.
    var screenDistance: Float = 15 {
        didSet { save(); if !draggingScreen { refitScreen() } }
    }
    /// The distances the grab bar can take the screen to (the slider's are narrower).
    static let screenDistanceRange: ClosedRange<Float> = 2 ... 80
    @ObservationIgnored private var draggingScreen = false
    /// Where the grab bar is taking the screen; `update` eases toward it.
    @ObservationIgnored private var screenTarget: simd_float4x4?
    /// The screen's up, chosen when it's placed (see `screenUp(for:)`).
    @ObservationIgnored private var screenUp = SIMD3<Float>(0, 1, 0)
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
        /// Optional: settings saved before it existed decode as off. Still
        /// written (true for `.always`) so an older build reads a sensible value.
        var headLocked: Bool?
        /// Optional: settings saved before it existed take `headLocked`.
        var headLockedMode: String?
        /// Optional: settings saved before it existed decode as full.
        var hudStabilization: Float?
        /// Optional: where the wearer left the HUD; before, it opened at home.
        var hudOffset: [Float]?
        var hudWidth: Float?
    }

    private init() {
        if let data = HypnosDefaults.store.data(forKey: Self.defaultsKey),
           let settings = try? JSONDecoder().decode(Settings.self, from: data) {
            screenDistance = settings.screenDistance
            screenWidthDegrees = settings.screenWidthDegrees
            dimsSurroundings = settings.dimsSurroundings
            headLockedMode = settings.headLockedMode.flatMap(RAVEHeadLockedSound.init(rawValue:))
                ?? ((settings.headLocked ?? false) ? .always : .off)
            hudStabilization = min(1, max(0, settings.hudStabilization ?? 1))
            if let offset = settings.hudOffset, offset.count == 3,
               let width = settings.hudWidth, width.isFinite {
                hudWidth = min(4, max(0.25, width))
                hudOffset = HUDFraming.clamp(offset: SIMD3(offset[0], offset[1], offset[2]),
                                             requestedWidth: hudWidth, aspect: hudAspect)
            }
        }
        RAVEMediaPolicy.headLockedSound = headLockedMode
    }

    private func save() {
        let settings = Settings(screenDistance: screenDistance, screenWidthDegrees: screenWidthDegrees,
                                dimsSurroundings: dimsSurroundings, headLocked: headLocked,
                                headLockedMode: headLockedMode.rawValue,
                                hudStabilization: hudStabilization,
                                hudOffset: [hudOffset.x, hudOffset.y, hudOffset.z], hudWidth: hudWidth)
        if let data = try? JSONEncoder().encode(settings) {
            HypnosDefaults.store.set(data, forKey: Self.defaultsKey)
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

    /// `setMode` for a host that owns the space (Nexus): nothing of SwiftUI's to pass.
    func setMode(_ newMode: CinemaMode, for owner: CinemaOwner) async {
        claim(owner)
        guard newMode != mode else { return }
        logger.info("Cinema: \(self.mode.rawValue, privacy: .public) → \(newMode.rawValue, privacy: .public)")
        if !newMode.showsPicture { screenAttached = false }
        mode = newMode
        if newMode == .bigScreen, let headPose { placeScreen(facing: headPose) }
        await sync(open: nil, dismiss: nil)
    }

    /// Whether `player` already plays the HUD's sound.
    func hudSoundApplied(to player: AVPlayer) -> Bool {
        let experience = player.intendedSpatialAudioExperience
        return headLocked(for: player) ? experience is FixedSpatialAudio : experience is AutomaticSpatialAudio
    }

    /// The sound a player in the HUD plays with: head-locked (`.fixed`) when
    /// its sound is head-locked (always, or stereo and mono under By Audio
    /// Layout), otherwise AVPlayer's automatic choice. Cheap when already
    /// right, so it can run every tick, which is also what picks up the
    /// audio probe's answer once it arrives.
    func applyHUDSound(to player: AVPlayer) {
        guard !hudSoundApplied(to: player) else { return }
        let locked = headLocked(for: player)
        player.intendedSpatialAudioExperience = locked
            ? .fixed(soundStageSize: .automatic) : AutomaticSpatialAudio.automatic
        logger.info("Cinema: HUD sound \(locked ? "head-locked" : "automatic", privacy: .public)")
    }

    /// Sets the mode without touching the space: the Settings page's picker,
    /// where there is no space to open. A film that holds the space for its
    /// head-locked sound keeps it until the next time the cinema syncs.
    func applyHeadLockedMode(_ newMode: RAVEHeadLockedSound) {
        guard headLockedMode != newMode else { return }
        headLockedMode = newMode
        save()
        RAVEMediaPolicy.headLockedSound = newMode
        logger.info("Cinema: head-locked sound \(newMode.rawValue, privacy: .public)")
    }

    func setHeadLockedMode(_ newMode: RAVEHeadLockedSound, for owner: CinemaOwner,
                           open: OpenImmersiveSpaceAction, dismiss: DismissImmersiveSpaceAction) async {
        applyHeadLockedMode(newMode)
        // Only the film's sound needs the space for it.
        guard owner == .film else { return }
        if self.owner != .film {
            guard headLocked else { return }
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
        if isOpen { await closeSpace(dismiss) }
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
        if !needsSpace, isOpen { await closeSpace(dismiss) }
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
        hudPrompt = nil
        screenPose = nil
        screenTarget = nil
    }

    private func sync(open: OpenImmersiveSpaceAction?, dismiss: DismissImmersiveSpaceAction?) async {
        guard needsSpace else {
            if isOpen { await closeSpace(dismiss) }
            return
        }
        guard !isOpen else { return }
        status = "Opening"
        if let spaceHost {
            // The host's space is one space for every module: nothing to close first.
            if await !spaceHost.joinCinemaSpace() { fallBackToWindow("Failed to open") }
            return
        }
        // One immersive space at a time: Spatial 3D closes first (a no-op
        // when none is open).
        guard let open, let dismiss else { return }
        await dismiss()
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

    /// Leaves the space: the host's, when there is one, else this app's own.
    private func closeSpace(_ dismiss: DismissImmersiveSpaceAction?) async {
        if let spaceHost { await spaceHost.leaveCinemaSpace() } else { await dismiss?() }
    }

    /// The HUD's close button: the owner's window closed, so the space follows.
    func releaseFromSpace(_ owner: CinemaOwner) async {
        guard self.owner == owner else { return }
        resetOwner()
        guard isOpen else { return }
        if let spaceHost { await spaceHost.leaveCinemaSpace() } else { await viewActions?.dismiss() }
    }

    /// The HUD's utilities button: back to the window.
    func returnToWindow(_ owner: CinemaOwner) async {
        if let spaceHost {
            claim(owner)
            guard mode != .window else { return }
            logger.info("Cinema: \(self.mode.rawValue, privacy: .public) → window")
            screenAttached = false
            mode = .window
            if !needsSpace, isOpen { await spaceHost.leaveCinemaSpace() }
        } else if let actions = viewActions {
            await setMode(.window, for: owner, open: actions.open, dismiss: actions.dismiss)
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

    func spaceAppeared(actions: (open: OpenImmersiveSpaceAction, dismiss: DismissImmersiveSpaceAction)? = nil) {
        viewActions = actions
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

    func spaceDisappeared() {
        viewActions = nil
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
        screenTarget = nil
        status = "Closed"
    }

    func noteScreenAttached(_ attached: Bool) {
        if screenAttached != attached { screenAttached = attached }
    }

    func noteScreenTap() { screenTaps += 1 }

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
        easeScreen(dt: dt)

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
        screenUp = Self.screenUp(for: head)
        // Upright, the screen goes level at eye height wherever the head
        // looks; lying back, it goes where the eyes look, tilted to face them.
        let look = -head.columns.2.xyz
        let forward = screenUp.y > 0.99 ? (Self.horizontal(look) ?? look) : simd_normalize(look)
        screenTarget = nil
        screenPose = Self.pose(at: position + forward * screenDistance, facing: position, up: screenUp)
        logger.info("Cinema: screen placed \(self.screenDistance, format: .fixed(precision: 1), privacy: .public) m ahead, \(self.screenWidth, format: .fixed(precision: 1), privacy: .public) m wide, upright \(self.screenUp.y > 0.99, privacy: .public)")
    }

    /// The screen's up: the room's while the head is roughly upright, the
    /// head's own when it leans back past ~45° (lying down), so the picture
    /// stays the right way up to the eyes.
    private static func screenUp(for head: simd_float4x4) -> SIMD3<Float> {
        let headUp = simd_normalize(head.columns.1.xyz)
        return headUp.y > 0.7 ? SIMD3(0, 1, 0) : headUp
    }

    /// Moves the screen by the grab bar. visionOS already scales an
    /// indirect drag by the target's distance, so the bar's own movement
    /// (`start + movement`) is where the screen goes, kept within
    /// `screenDistanceRange` and turned to face the head. The screen eases
    /// toward it each frame (`dragEaseSeconds`), so hand jitter doesn't
    /// jump it about. The screen keeps its angular size.
    /// - Parameters:
    ///   - start: the screen's centre when the drag began.
    ///   - movement: the drag's translation so far, in the space's metres.
    func dragScreen(from start: SIMD3<Float>, by movement: SIMD3<Float>) {
        guard let head = headPose?.columns.3.xyz else { return }
        let toMoved = start + movement - head
        let length = simd_length(toMoved)
        guard length > 0.1 else { return }
        let distance = min(max(length, Self.screenDistanceRange.lowerBound), Self.screenDistanceRange.upperBound)
        let position = head + toMoved / length * distance
        screenTarget = Self.pose(at: position, facing: head, up: screenUp)
        draggingScreen = true
        screenDistance = distance
        draggingScreen = false
    }

    /// How long the screen takes to catch up with the grab bar (time constant).
    private static let dragEaseSeconds: Float = 0.12

    /// Eases the screen toward the grab bar's target.
    private func easeScreen(dt: Float) {
        guard let target = screenTarget else { return }
        guard let current = screenPose else { screenPose = target; screenTarget = nil; return }
        let k = 1 - expf(-max(dt, 0) / Self.dragEaseSeconds)
        let from = current.columns.3.xyz, to = target.columns.3.xyz
        let rotation = simd_slerp(simd_quatf(current), simd_quatf(target), k)
        var pose = simd_float4x4(rotation)
        pose.columns.3 = SIMD4(from + (to - from) * k, 1)
        screenPose = pose
        if simd_distance(from, to) < 0.002 { screenPose = target; screenTarget = nil }
    }

    /// A changed distance moves the screen along its own heading from the listener.
    private func refitScreen() {
        guard let screenPose, let centre = listener else { return }
        screenTarget = nil
        let forward = simd_normalize(-screenPose.columns.2.xyz)
        var position = centre + forward * screenDistance
        if screenUp.y > 0.99, abs(forward.y) < 1e-3 { position.y = screenPose.columns.3.y }
        var pose = screenPose
        pose.columns.3 = SIMD4(position, 1)
        self.screenPose = pose
    }

    /// A pose at `position` whose +z points at `eye`, with +y as near `up` as that allows.
    private static func pose(at position: SIMD3<Float>, facing eye: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let toEye = eye - position
        guard simd_length(toEye) > 1e-3 else { return pose(at: position, forward: -up, fallback: SIMD3(0, 0, -1)) }
        let z = simd_normalize(toEye)
        var x = simd_cross(up, z)
        if simd_length(x) < 1e-3 { x = simd_cross(SIMD3(0, 0, 1), z) }
        x = simd_normalize(x)
        let y = simd_cross(z, x)
        return simd_float4x4(columns: (SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(position, 1)))
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

extension SIMD4 where Scalar == Float {
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
struct CinemaHUDControls: View {
    @Bindable private var cinema = Cinema.shared
    let presentation: RAVEImmersivePlayerPresentation

    var body: some View {
        Group { if let controls = cinema.hudControlsView { controls } }
            .environment(\.raveImmersivePlayerPresentation, presentation)
            .coordinateSpace(name: RAVEImmersivePlayerPresentation.coordinateSpace)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { presentation.controlsSize = $0 }
    }
}

struct CinemaHUDClose: View {
    let closePlayer: () -> Void
    var body: some View {
        Button("Close Player", systemImage: "xmark", action: closePlayer)
            .labelStyle(.iconOnly).buttonStyle(.bordered).buttonBorderShape(.circle)
    }
}

struct CinemaHUDUtilities: View {
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

/// The owner's skip button and notices, drawn over the HUD's picture.
struct CinemaHUDPrompt: View {
    private let cinema = Cinema.shared
    var body: some View {
        Group { if let prompt = cinema.hudPrompt { prompt } }
            .animation(.easeInOut(duration: 0.2), value: cinema.hudPrompt == nil)
    }
}

struct CinemaHUDMenuAttachment: View {
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
            Text("Head-Locked Sound")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
            ForEach(RAVEHeadLockedSound.allCases, id: \.self) { sound in
                Button {
                    close()
                    Task {
                        await cinema.setHeadLockedMode(sound, for: owner,
                                                       open: openImmersiveSpace, dismiss: dismissImmersiveSpace)
                    }
                } label: {
                    PlayerChoiceRow(sound.title, isChecked: sound == cinema.headLockedMode)
                }
                .help(sound.help)
            }
            if cinema.mode(for: owner) == .hud {
                Divider()
                HUDStabilizationControl()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
        .accessibilityIdentifier("player.cinema")
    }
}

/// The HUD's Stabilization slider, in the Cinema menu while the HUD is up:
/// how much range of motion the picture keeps against the head. Less holds it
/// closer; the far left locks it to the head.
struct HUDStabilizationControl: View {
    @Bindable private var cinema = Cinema.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Stabilization: \(Int((cinema.hudStabilization * 100).rounded()))%").font(.caption)
            Slider(value: $cinema.hudStabilization, in: 0 ... 1, step: 0.05)
                .frame(minWidth: 120)
                .accessibilityIdentifier("player.cinema.hudStabilization")
            HStack {
                Text("Locked").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { cinema.hudStabilization = 1 }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(cinema.hudStabilization == 1)
                Spacer()
                Text("Smooth").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// A video window's half of the cinema: Big Screen needs the AVFoundation
/// renderer, and the window's player goes to the screen.
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
            // AI 3D and live 3D lend their plane to the screen.
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
        // Live 3D and AI 3D come along (their plane moves to the screen).
        if windowModel.playbackRenderer == .webKit,
           !windowModel.switchToTranscodedStream(reason: "The Big Screen needs the AVFoundation renderer") {
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
            && (HypnosDefaults.store.string(forKey: StereoSubtitleStyle.key)
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
            player.intendedSpatialAudioExperience = cinema.headLocked(for: player)
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
            Slider(value: $cinema.screenDistance, in: Cinema.screenDistanceRange, step: 1)
        }
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "Screen size: %.0f° (%.1f m wide)", cinema.screenWidthDegrees, cinema.screenWidth))
                .font(.caption)
            Slider(value: $cinema.screenWidthDegrees, in: 30 ... 100, step: 1)
        }
        Toggle("Dim Surroundings", isOn: $cinema.dimsSurroundings)
        ForearmSleeveSettings()
        Text("Cinema: \(cinema.status)").font(.caption).foregroundStyle(.secondary)
    }
}
#endif
