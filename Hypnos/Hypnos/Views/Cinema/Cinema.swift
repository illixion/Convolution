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
   has the screen as its front wall. AI 3D and live 3D draw in the window, so
   Big Screen ends them, and choosing them ends Big Screen.
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
import AVFoundation
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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .window: "Window"
        case .roomSound: "Room Sound"
        case .bigScreen: "Big Screen"
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
        case .video: [.window, .bigScreen]
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
    /// The owner's subtitles, drawn on the screen.
    private(set) var screenSubtitles: CinemaSubtitles?
    /// Taps on the screen, for the owner's window to toggle its controls.
    private(set) var screenTaps = 0
    private(set) var status = "Closed"

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
        if case .video = owner { return mode == .bigScreen }
        return screenAttached
    }

    /// The film's object audio plays in the space rather than its window.
    var hostsFilmSound: Bool { isOpen && owner == .film }

    private var needsSpace: Bool {
        switch owner {
        case .film: mode != .window || headLocked
        case .video: mode == .bigScreen
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
        if newMode != .bigScreen { screenAttached = false }
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

    func setSubtitles(_ subtitles: CinemaSubtitles, for owner: CinemaOwner) {
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
        screenSubtitles = nil
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

// MARK: - The space

/// The cinema space's content: the film's object-audio stage and, for Big
/// Screen, the owner's picture on a screen.
struct CinemaSpaceView: View {
    @Bindable private var cinema = Cinema.shared
    private let session = FilmSession.shared
    @State private var screen = Entity()
    /// A video window's picture: a `VideoPlayerComponent` on its player.
    @State private var playerPicture = Entity()
    @State private var playerPictureSource: ObjectIdentifier?
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
                content.add(screen)
            }
            .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { _ in cinema.noteScreenTap() })
        }
        .preferredSurroundingsEffect(cinema.mode == .bigScreen && cinema.dimsSurroundings ? .systemDark : nil)
        .onAppear { cinema.spaceAppeared() }
        .onDisappear { cinema.spaceDisappeared() }
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
        if cinema.owner != .film || cinema.mode != .bigScreen, filmPicture.parent === screen {
            filmPicture.removeFromParent()
        }
        // A video window between players keeps the last one's picture.
        if cinema.owner == .film || cinema.owner == nil || cinema.mode != .bigScreen {
            releasePlayerPicture()
        }
        guard cinema.mode == .bigScreen, let owner = cinema.owner, let pose = cinema.screenPose else {
            releaseSubtitles()
            cinema.noteScreenAttached(false)
            return
        }
        screen.setTransformMatrix(pose, relativeTo: nil)

        let picture: Entity
        let aspect: Float
        switch owner {
        case .film:
            let video = session.player.video
            picture = filmPicture
            aspect = video.pictureAspect ?? 16 / 9
            video.pictureAttached = true
        case .video:
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
        // The video component's mesh is aspect × 1 m, so its scale is its height.
        let height = cinema.screenWidth / max(aspect, 0.1)
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
        cinema.noteScreenAttached(true)
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
        let scale = cinema.screenWidth / bounds.extents.x
        let transform = Transform(scale: SIMD3(repeating: scale), translation: SIMD3(0, 0, 0.05))
        if subtitles.transform != transform { subtitles.transform = transform }
    }

    private func releaseSubtitles() {
        guard subtitlesSource != nil else { return }
        subtitles.components.remove(ViewAttachmentComponent.self)
        subtitles.removeFromParent()
        subtitlesSource = nil
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
            Text(Cinema.shared.screenAttached ? "Playing on the Big Screen" : "Opening the Big Screen…").font(.title2)
            HStack(spacing: 12) {
                Button("Place in Front of Me", systemImage: "scope") { Cinema.shared.placeScreenInFront() }
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
                         onOpenChanged: onOpenChanged) { close in
            ForEach(owner.modes) { mode in
                Button {
                    close()
                    Task { await cinema.setMode(mode, for: owner, open: openImmersiveSpace, dismiss: dismissImmersiveSpace) }
                } label: {
                    PlayerChoiceRow(mode.title, isChecked: mode == cinema.mode(for: owner))
                }
                .disabled(mode == .bigScreen && !bigScreenAvailable)
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
    private var cinema: Cinema { .shared }
    private var owner: CinemaOwner { .video(ObjectIdentifier(windowModel)) }
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    private var onBigScreen: Bool { cinema.mode(for: owner) == .bigScreen }

    func body(content: Content) -> some View {
        content
            .onChange(of: onBigScreen, initial: true) { _, on in
                windowModel.holdsBigScreen = on
                if on { prepare() }
            }
            .onChange(of: windowModel.playbackRenderer) {
                if onBigScreen { prepare() }
            }
            .onChange(of: windowModel.nativePlayerGeneration) { lendPlayer() }
            // AI 3D, live 3D and the immersive player draw elsewhere: picking
            // one ends Big Screen.
            .onChange(of: windowModel.showsStereoPicture || windowModel.usesImmersiveStereo) { _, stereo in
                guard stereo, onBigScreen else { return }
                Task { await cinema.setMode(.window, for: owner, open: openImmersiveSpace, dismiss: dismissImmersiveSpace) }
            }
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
        let model = windowModel
        cinema.setSubtitles(CinemaSubtitles(controller: model.subtitles, time: { [weak model] in model?.currentTime ?? 0 }),
                            for: owner)
        if windowModel.pseudo3DEnabled { windowModel.disablePseudo3D() }
        if windowModel.stereoscopicOverride == true { windowModel.stereoscopicOverride = false }
        if windowModel.playbackRenderer == .webKit,
           !windowModel.switchToTranscodedStream(reason: "Big Screen needs the AVFoundation renderer") {
            let owner = owner
            Task {
                await cinema.fail("This video can't play on the Big Screen: the server has no transcode this device can decode.",
                                  for: owner, dismiss: dismissImmersiveSpace)
            }
            windowModel.showQualityNotice("This video can't play on the Big Screen.")
            return
        }
        lendPlayer()
    }

    private func lendPlayer() {
        guard cinema.owner == owner else { return }
        cinema.setScreenPlayer(windowModel.playbackRenderer == .nativeMetal ? windowModel.nativePlayer : nil, for: owner)
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
