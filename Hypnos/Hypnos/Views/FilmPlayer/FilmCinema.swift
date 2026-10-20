/*
 Hypnos - the film player's cinema: an immersive space of its own

 A window can't see the head and is held to the system's placement limits,
 so the film player can open a mixed immersive space (`FilmCinema.spaceID`)
 that does two things a window can't:

 - **Room Sound**: the object audio's stage moves into the space and is
   centred on the wearer's real head (ARKit's device anchor, which only an
   open immersive space receives), facing the film window. The window's
   pose comes from an entity in it (`FilmWindowMarker`) read with
   `transformMatrix(relativeTo: .immersiveSpace)`. The picture stays in
   the window.
 - **Big Screen**: the picture's entity (`FilmVideoPlayer.videoEntity`,
   the same `VideoPlayerComponent` and renderer, so nothing reloads) moves
   onto a screen in the space, `screenDistance` metres ahead and
   `screenWidthDegrees` wide: further and larger than a window may go. The
   surroundings dim as in Apple's players, the window shows a card with the
   way back, and the room's front wall is the screen.

 The space asks to coexist with a system environment
 (`immersiveEnvironmentBehavior(.coexist)`, visionOS 26), so Mount Hood and
 the rest stay up around the screen. Our own windows stay visible in our
 mixed space; other apps' windows hide while it is open. An app has one
 immersive space at a time, so opening the cinema closes Spatial 3D or the
 immersive video player first.

 The room follows the head's position slowly (1.5 s), so leaning gives a
 little parallax and walking re-centres it. Positions are set in scene
 space, which in an immersive space is ARKit's origin.

 AI 3D and in-picture subtitles draw in the window, so Big Screen stops 3D
 and has no subtitles yet.
 */

#if os(visionOS)
import ARKit
import DebugTrace
import QuartzCore
import RAVEFilm
import RealityKit
import simd
import SwiftUI

enum FilmCinemaMode: String, CaseIterable, Identifiable {
    /// No space: picture and sound in the window.
    case window
    /// The sound around the head; the picture stays in the window.
    case roomSound
    /// The picture on a screen in the space, the sound around the head.
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

@MainActor
@Observable
final class FilmCinema {
    static let shared = FilmCinema()
    static let spaceID = "FilmCinemaSpace"

    /// What the viewer chose.
    private(set) var mode = FilmCinemaMode.window
    /// The space's view is up.
    private(set) var isOpen = false
    /// The space's screen holds the picture's entity, so the window doesn't.
    private(set) var screenAttached = false
    /// The screen's centre (+z toward the viewer), in the space; nil until
    /// a head pose placed it.
    private(set) var screenPose: simd_float4x4?
    /// Taps on the screen, for the window to toggle its controls.
    private(set) var screenTaps = 0
    private(set) var status = "Closed"

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
    /// The room's pose for `FilmStageView(roomPose:)`.
    @ObservationIgnored private(set) var roomPose: simd_float4x4?
    @ObservationIgnored private var arSession: ARKitSession?
    @ObservationIgnored private var worldTracking: WorldTrackingProvider?
    @ObservationIgnored private var loop: Task<Void, Never>?

    private let logger = DebugLogger(subsystem: "com.illixion.hypnos", category: "FilmCinema")
    private static let defaultsKey = "filmPlayer.cinema"
    /// Seconds the room takes to follow the head's position.
    private static let followSeconds: Float = 1.5

    private struct Settings: Codable {
        var screenDistance: Float
        var screenWidthDegrees: Float
        var dimsSurroundings: Bool
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let settings = try? JSONDecoder().decode(Settings.self, from: data) {
            screenDistance = settings.screenDistance
            screenWidthDegrees = settings.screenWidthDegrees
            dimsSurroundings = settings.dimsSurroundings
        }
    }

    private func save() {
        let settings = Settings(screenDistance: screenDistance, screenWidthDegrees: screenWidthDegrees,
                                dimsSurroundings: dimsSurroundings)
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    /// The screen's width in metres at its distance.
    var screenWidth: Float { 2 * screenDistance * tanf(screenWidthDegrees * .pi / 360) }

    // MARK: Opening and closing

    func setMode(_ newMode: FilmCinemaMode, open: OpenImmersiveSpaceAction, dismiss: DismissImmersiveSpaceAction) async {
        guard newMode != mode else { return }
        logger.info("Cinema: \(self.mode.rawValue, privacy: .public) → \(newMode.rawValue, privacy: .public)")
        // The window takes the picture back before anything closes.
        if newMode != .bigScreen { screenAttached = false }
        mode = newMode
        if newMode == .window {
            if isOpen { await dismiss() }
            return
        }
        if newMode == .bigScreen, let headPose { placeScreen(facing: headPose) }
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

    // MARK: The space's lifecycle (FilmCinemaSpaceView)

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
        screenAttached = false
        mode = .window
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

/// The cinema space's content: the object audio's stage and, for Big
/// Screen, the picture's entity on a screen.
struct FilmCinemaSpaceView: View {
    @Bindable private var cinema = FilmCinema.shared
    private let session = FilmSession.shared
    @State private var screen = Entity()

    var body: some View {
        ZStack {
            FilmStageView(player: session.player, roomPose: { FilmCinema.shared.roomPose })
            RealityView { content in
                screen.name = "film-cinema-screen"
                content.add(screen)
            }
            .gesture(SpatialTapGesture().targetedToEntity(session.player.video.videoEntity).onEnded { _ in
                cinema.noteScreenTap()
            })
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
        let video = session.player.video
        let picture = video.videoEntity
        guard cinema.mode == .bigScreen, let pose = cinema.screenPose else {
            // The window re-adds the entity to its own view when it shows it again.
            cinema.noteScreenAttached(false)
            return
        }
        screen.setTransformMatrix(pose, relativeTo: nil)
        if picture.parent !== screen {
            screen.addChild(picture)
            AppLogger.filmPlayer.info("Cinema: picture moved to the big screen")
        }
        // The mesh is aspect × 1 m, so its scale is its height.
        let height = cinema.screenWidth / max(video.pictureAspect ?? 16 / 9, 0.1)
        let transform = Transform(scale: SIMD3(repeating: height))
        if picture.transform != transform { picture.transform = transform }
        if picture.components[OpacityComponent.self]?.opacity != 1 {
            picture.components.set(OpacityComponent(opacity: 1))
        }
        if picture.components[InputTargetComponent.self]?.isEnabled != true {
            picture.components.set(InputTargetComponent())
        }
        video.pictureAttached = true
        cinema.noteScreenAttached(true)
    }
}

// MARK: - The window's side

/// An entity at the film window's centre whose pose in the cinema space
/// tells the stage where the window is.
struct FilmWindowMarker: View {
    private let cinema = FilmCinema.shared
    @State private var marker = Entity()

    var body: some View {
        RealityView { content in
            marker.name = "film-window-marker"
            content.add(marker)
        }
        .task(id: cinema.isOpen) {
            guard cinema.isOpen else { return }
            while !Task.isCancelled {
                if let pose = marker.transformMatrix(relativeTo: .immersiveSpace) { cinema.windowPose = pose }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

/// What the film window shows while the picture is on the big screen.
struct FilmBigScreenCard: View {
    let onTap: () -> Void
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles.tv").font(.system(size: 44))
            Text("Playing on the Big Screen").font(.title2)
            HStack(spacing: 12) {
                Button("Place in Front of Me", systemImage: "scope") { FilmCinema.shared.placeScreenInFront() }
                Button("Back to Window", systemImage: "macwindow") {
                    Task { await FilmCinema.shared.setMode(.window, open: openImmersiveSpace, dismiss: dismissImmersiveSpace) }
                }
            }
        }
        .padding(32)
        .glassBackgroundEffect()
        .contentShape(.rect)
        .onTapGesture(perform: onTap)
    }
}

/// The transport's Cinema choice.
struct FilmCinemaMenu: View {
    var onOpenChanged: (Bool) -> Void = { _ in }
    private let cinema = FilmCinema.shared
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        PlayerChoiceMenu(title: "Cinema", systemImage: "sparkles.tv",
                         badge: cinema.mode == .window ? nil : cinema.mode.title,
                         badgeIsActive: cinema.mode != .window,
                         help: "Sound around you, or the picture on a big screen",
                         onOpenChanged: onOpenChanged) { close in
            ForEach(FilmCinemaMode.allCases) { mode in
                Button {
                    close()
                    Task { await cinema.setMode(mode, open: openImmersiveSpace, dismiss: dismissImmersiveSpace) }
                } label: {
                    Label(mode.title, systemImage: "checkmark")
                        .labelStyle(CheckmarkLabelStyle(isChecked: mode == cinema.mode))
                }
            }
        }
        .accessibilityIdentifier("player.cinema")
    }
}

/// Sound and Picture's Cinema section.
struct FilmCinemaSettings: View {
    @Bindable private var cinema = FilmCinema.shared

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
