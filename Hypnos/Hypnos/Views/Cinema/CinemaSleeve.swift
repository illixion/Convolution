//
//  CinemaSleeve.swift
//  Hypnos
//
//  A media remote worn on the forearm while a picture is in the cinema's space (HUD or Big
//  Screen): RAVE Engine's `RAVESleevePresets.mediaRemote` drawn by `RAVEPanel`, on the back of
//  the forearm, shown while that face is turned to the eyes and pressed with the other index
//  finger or by looking and pinching. The title, a seek bar, back / play-pause / forward / next,
//  and the volume, wired to whichever player owns the cinema (`CinemaOwner`).
//
//  Big Screen had no controls in the space at all (they stayed in the window, behind the
//  viewer or across the room), and the HUD's strip hides with the chrome. The sleeve is the
//  portfolio's hand-anchored HUD (RAVEEngine's CLAUDE.md, "About `RAVESleeve`"); the host half
//  it shares with the other apps is `RAVESleeveWearer`.
//
//  Hands come from a session of the sleeve's own (hand tracking asks the wearer once), or from
//  the host's when Nexus owns the space (`hostHands`). Without hands there is no sleeve and
//  nothing else changes.
//

#if os(visionOS)

import ARKit
import Combine
import DebugTrace
import Observation
import QuartzCore
import RAVEFilm
import RAVEPanel
import RealityKit
import simd
import SwiftUI

@MainActor
@Observable
final class CinemaSleeve {
    static let shared = CinemaSleeve()

    private static let enabledKey = "cinema.sleeve.enabled"
    private static let armKey = "cinema.sleeve.arm"
    private typealias Tile = RAVESleevePresets.MediaTile

    /// Seconds Back and Forward jump.
    static let skipSeconds = 10
    static let layout = RAVESleeveLayout(outer: [
        RAVESleevePresets.mediaRemote(skipSeconds: skipSeconds, volume: true),
    ])

    /// Wear the remote while a picture is in the space.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            HypnosDefaults.store.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                if spaceOpen { startHands() }
            } else {
                // The tiles fade from `tick`, which keeps stepping while the space is open.
                stopHands()
                scrub = nil
            }
        }
    }

    /// The arm it is worn on. The left by default: the non-dominant arm of most
    /// wearers, pressed with the dominant hand.
    var arm: RAVESleeveSide {
        didSet {
            guard arm != oldValue else { return }
            HypnosDefaults.store.set(arm.rawValue, forKey: Self.armKey)
        }
    }

    /// A face of the sleeve is showing, so the space draws over the arms
    /// (`CinemaSpace.hidesUpperLimbs`).
    private(set) var isVisible = false
    /// Why there is no sleeve, for Settings: nil while hands are tracked.
    private(set) var handsStatus: String?

    /// The hands of a host that owns the space and its ARKit session (Nexus); nil in
    /// this app's own space, where the sleeve runs hand tracking itself.
    @ObservationIgnored var hostHands: (@MainActor () -> (left: HandAnchor?, right: HandAnchor?)?)?
    /// A made-up arm for the simulator, which has no hands: the angle (radians) the
    /// back of the forearm is turned from the eyes. Set by the debug server.
    @ObservationIgnored var simulatedAngle: Float?

    @ObservationIgnored let wearer = RAVESleeveWearer(layout: CinemaSleeve.layout)
    @ObservationIgnored private var spaceOpen = false
    @ObservationIgnored private var handSession: ARKitSession?
    @ObservationIgnored private var handFeed: RAVESleeveHandFeed?
    @ObservationIgnored private var subscription: (any Cancellable)?
    @ObservationIgnored private weak var subscribedScene: RealityKit.Scene?
    /// Where the seek bar is being dragged to; applied when it is let go, so a
    /// drag is one seek and not one per frame.
    @ObservationIgnored private var scrub: Float?
    @ObservationIgnored private var scrubSeen: TimeInterval = 0

    private let logger = DebugLogger(subsystem: "com.illixion.hypnos", category: "CinemaSleeve")

    private init() {
        let store = HypnosDefaults.store
        isEnabled = store.object(forKey: Self.enabledKey) == nil ? true : store.bool(forKey: Self.enabledKey)
        arm = store.string(forKey: Self.armKey).flatMap(RAVESleeveSide.init(rawValue:)) ?? .left
    }

    // MARK: The space

    /// Puts the tiles under the space's root and steps the sleeve on every scene
    /// update. `CinemaSpace` calls it from its placement loop, since the root has
    /// no scene until the space is up.
    func attach(to root: Entity) {
        if wearer.root.parent !== root { root.addChild(wearer.root) }
        guard let scene = root.scene, scene !== subscribedScene else { return }
        subscription?.cancel()
        subscribedScene = scene
        subscription = scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func spaceOpened() {
        spaceOpen = true
        if isEnabled { startHands() }
    }

    func spaceClosed() {
        spaceOpen = false
        stopHands()
        subscription?.cancel()
        subscription = nil
        subscribedScene = nil
        wearer.release()
        scrub = nil
        isVisible = false
    }

    // MARK: Hands

    private func startHands() {
        guard hostHands == nil, handSession == nil else { return }
        guard HandTrackingProvider.isSupported else {
            handsStatus = "Hand tracking isn't available here"
            return
        }
        let session = ARKitSession()
        let feed = RAVESleeveHandFeed()
        handSession = session
        handsStatus = "Waiting for hand tracking"
        Task { @MainActor [weak self] in
            let answer = await session.requestAuthorization(for: [.handTracking])
            guard let self, self.handSession === session else { return }
            guard answer[.handTracking] == .allowed else {
                self.logger.notice("Sleeve: hand tracking not allowed")
                self.handsStatus = "Hand tracking isn't allowed for Convolution (Settings › Apps)"
                self.handSession = nil
                return
            }
            do {
                try await session.run([feed.provider])
            } catch {
                self.logger.error("Sleeve: hand tracking failed: \(error.localizedDescription, privacy: .public)")
                self.handsStatus = "Hand tracking failed to start"
                if self.handSession === session { self.handSession = nil }
                return
            }
            guard self.handSession === session else {
                session.stop()
                return
            }
            feed.start()
            self.handFeed = feed
            self.handsStatus = nil
            self.logger.info("Sleeve: hand tracking running, worn on the \(self.arm.rawValue, privacy: .public) arm")
        }
    }

    private func stopHands() {
        handFeed?.stop()
        handFeed = nil
        handSession?.stop()
        handSession = nil
        handsStatus = nil
    }

    // MARK: Per frame

    private func tick() {
        let cinema = Cinema.shared
        guard spaceOpen else { return }
        guard isEnabled else {
            // Switched off while showing: stepped with no arm, so the tiles fade
            // rather than freeze where they were.
            if isVisible || wearer.source != .none {
                wearer.update(worn: nil, other: nil, head: SIMD3(0, 1.5, 0), showAllowed: false)
                if wearer.isVisible != isVisible { isVisible = wearer.isVisible }
                if !wearer.isVisible { wearer.release() }
            }
            return
        }
        let remote = Remote.current
        let allowed = cinema.mode.showsPicture && remote != nil
        refreshTiles(remote)

        let device = cinema.hudDevicePose()
        let events: [RAVESleeveEvent]
        if let simulatedAngle {
            let head = device?.columns.3.xyz ?? SIMD3(0, 1.5, 0)
            let forward = device.map { -$0.columns.2.xyz } ?? SIMD3(0, 0, -1)
            events = wearer.update(simulated: RAVESleeveWearer.simulatedArm(head: head, forward: forward, side: arm,
                                                                            angle: simulatedAngle),
                                   head: head, showAllowed: allowed)
        } else if let device {
            let anchors = hostHands?() ?? handFeed?.anchors()
            let worn = arm == .left ? anchors?.left : anchors?.right
            let other = arm == .left ? anchors?.right : anchors?.left
            events = wearer.update(worn: worn, other: other, head: device.columns.3.xyz, showAllowed: allowed)
        } else {
            // No head yet: nothing to turn a face toward.
            events = wearer.update(worn: nil, other: nil, head: SIMD3(0, 1.5, 0), showAllowed: false)
        }
        for event in events { handle(event, remote) }

        // The seek bar let go: one seek, to where it was left.
        if let fraction = scrub {
            let held = wearer.snapshot?.tiles.first { $0.tile.id == Tile.progress }?.isPressed ?? false
            if !held, CACurrentMediaTime() - scrubSeen > 0.12 {
                scrub = nil
                remote?.seek(toFraction: Double(fraction))
            }
        }
        if wearer.isVisible != isVisible { isVisible = wearer.isVisible }
    }

    private func refreshTiles(_ remote: Remote?) {
        func set(_ id: String, _ state: RAVESleeveTileState) {
            if wearer.sleeve.states[id] != state { wearer.sleeve.states[id] = state }
        }
        guard let remote else {
            set(Tile.title, RAVESleeveTileState(text: "Nothing playing"))
            for id in [Tile.progress, Tile.back, Tile.playPause, Tile.forward, Tile.next, Tile.volume] {
                set(id, RAVESleeveTileState(disabled: true))
            }
            return
        }
        let duration = remote.duration
        let seekable = duration > 0
        let fraction = scrub ?? (seekable ? Float(min(max(remote.time / duration, 0), 1)) : 0)
        let shownTime = scrub.map { Double($0) * duration } ?? remote.time
        set(Tile.title, RAVESleeveTileState(text: remote.title))
        set(Tile.progress, RAVESleeveTileState(
            fraction: fraction,
            text: seekable ? "\(Self.clock(shownTime)) / \(Self.clock(duration))" : Self.clock(shownTime),
            disabled: !seekable))
        set(Tile.back, RAVESleeveTileState(disabled: !seekable))
        set(Tile.forward, RAVESleeveTileState(disabled: !seekable))
        set(Tile.playPause, RAVESleeveTileState(isOn: remote.isPlaying, text: remote.isPlaying ? "Pause" : "Play"))
        set(Tile.next, RAVESleeveTileState(disabled: !remote.canPlayNext))
        set(Tile.volume, RAVESleeveTileState(fraction: Float(remote.volume),
                                             text: remote.isMuted ? "Muted" : "Volume \(Int((remote.volume * 100).rounded()))%"))
    }

    private func handle(_ event: RAVESleeveEvent, _ remote: Remote?) {
        guard let remote, let action = event.action else { return }
        typealias Action = RAVESleevePresets.MediaAction
        switch (action.id, event.kind) {
        case (Action.play, .toggled(let play)):
            logger.info("Sleeve: \(play ? "play" : "pause", privacy: .public) by \(event.source.rawValue, privacy: .public)")
            remote.setPlaying(play)
        case (Action.skip, .fired):
            guard let seconds = action.argument.flatMap(Double.init) else { return }
            logger.info("Sleeve: skip \(Int(seconds), privacy: .public) s by \(event.source.rawValue, privacy: .public)")
            remote.skip(by: seconds)
        case (Action.next, .fired):
            logger.info("Sleeve: next by \(event.source.rawValue, privacy: .public)")
            remote.playNext()
        case (Action.seek, .value(let fraction)):
            scrub = fraction
            scrubSeen = CACurrentMediaTime()
        case (Action.volume, .value(let fraction)):
            remote.setVolume(Double(fraction))
        default:
            break
        }
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded())
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    // MARK: Debug

    func status() -> [String: Any] {
        var out = wearer.status()
        out["enabled"] = isEnabled
        out["arm"] = arm.rawValue
        out["spaceOpen"] = spaceOpen
        out["hands"] = handsStatus ?? (hostHands != nil ? "host" : (handFeed != nil ? "running" : "off"))
        out["owner"] = Remote.current?.kind ?? "none"
        if let simulatedAngle { out["simulatedAngleDegrees"] = Double(simulatedAngle * 180 / .pi) }
        return out
    }

    /// The debug server's press: a tile by id, as a pinch would; a slider goes to
    /// `fraction`.
    func press(_ tile: String, seconds: Double, fraction: Float?) {
        if let fraction {
            wearer.sleeve.pressBegan(tile, now: CACurrentMediaTime(), source: .remote)
            wearer.sleeve.setValue(tile, fraction: fraction, source: .remote)
            wearer.sleeve.pressEnded(tile, now: CACurrentMediaTime())
        } else {
            wearer.press(tile, seconds: seconds)
        }
    }
}

// MARK: - The player behind the remote

/// The cinema's owner as a transport: the film player, or the video window whose
/// picture is in the space. The same calls its own controls make.
@MainActor
private struct Remote {
    let kind: String
    let title: String
    let isPlaying: Bool
    let time: Double
    let duration: Double
    let volume: Double
    let isMuted: Bool
    let canPlayNext: Bool
    let setPlaying: (Bool) -> Void
    let skip: (Double) -> Void
    let seek: (Double) -> Void
    let setVolume: (Double) -> Void
    let playNext: () -> Void

    func skip(by seconds: Double) { skip(seconds) }
    func seek(toFraction fraction: Double) { if duration > 0 { seek(fraction * duration) } }

    static var current: Remote? {
        let cinema = Cinema.shared
        switch cinema.owner {
        case .film:
            let session = FilmSession.shared
            guard let item = session.loadedItem else { return nil }
            let player = session.player
            return Remote(
                kind: "film", title: item.name, isPlaying: player.isPlaying,
                time: player.currentTime, duration: player.duration,
                volume: Double(player.volume), isMuted: false, canPlayNext: false,
                setPlaying: { $0 ? player.play() : player.pause() },
                skip: { seconds in
                    let target = player.currentTime + seconds
                    player.seek(to: min(max(target, 0), player.duration > 0 ? player.duration : target))
                },
                seek: { player.seek(to: $0) },
                setVolume: { value in
                    player.volume = Float(value)
                    PlayerVolume.saved = value
                },
                playNext: {})
        case .video(let id):
            guard let model = cinema.hudVideoModel, ObjectIdentifier(model) == id else { return nil }
            return Remote(
                kind: "video", title: model.video.title ?? "Video", isPlaying: !model.isPaused,
                time: model.currentTime, duration: model.duration,
                volume: model.isMuted ? 0 : model.volume, isMuted: model.isMuted,
                canPlayNext: model.hasNextVideo,
                setPlaying: { [weak model] play in
                    guard let model, model.isPaused == play else { return }
                    model.togglePlayPause()
                },
                skip: { [weak model] in model?.seek(by: $0) },
                seek: { [weak model] in model?.endScrub(at: $0) },
                setVolume: { [weak model] value in
                    guard let model else { return }
                    model.setVolume(value)
                    // Turning the volume up is asking to hear it.
                    if model.isMuted, value > 0 { model.toggleMute() }
                },
                playNext: { [weak model] in model?.nextVideo() })
        case nil:
            return nil
        }
    }
}

// MARK: - Settings

/// Sound and Picture's Cinema section: the remote on the forearm.
struct CinemaSleeveSettings: View {
    @Bindable private var sleeve = CinemaSleeve.shared

    var body: some View {
        Toggle("Remote on Your Forearm", isOn: $sleeve.isEnabled)
        if sleeve.isEnabled {
            Picker("Worn On", selection: $sleeve.arm) {
                Text("Left Arm").tag(RAVESleeveSide.left)
                Text("Right Arm").tag(RAVESleeveSide.right)
            }
            .pickerStyle(.segmented)
        }
        Text(sleeve.handsStatus
             ?? "In HUD and Big Screen, turn the back of your forearm toward you for play, seek, skip and volume. Press a tile with your other index finger, or look at it and pinch.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Debug endpoints

@MainActor
enum CinemaSleeveEndpoints {
    static var all: [DebugEndpoint] {
        let sleeve = CinemaSleeve.shared
        let tiles = [RAVESleevePresets.MediaTile.back, RAVESleevePresets.MediaTile.playPause,
                     RAVESleevePresets.MediaTile.forward, RAVESleevePresets.MediaTile.next,
                     RAVESleevePresets.MediaTile.progress, RAVESleevePresets.MediaTile.volume]
        return [
            .untyped("cinemaSleeve", kind: .query,
                     "The media remote worn on the forearm in the cinema's space (HUD and Big Screen): enabled, which "
                     + "arm, whether hands are tracked (or why not), whether it shows, how steadied it is, and each "
                     + "tile's place and state (title text, progress fraction, play/pause on, disabled).") { _ in
                sleeve.status()
            },
            .untyped("setCinemaSleeve", kind: .command,
                     "Sets the forearm remote: `enabled`, `arm` (left or right), and for the simulator, which has no "
                     + "hands, `simulatedAngle` in degrees (0 turns the back of a made-up forearm to the eyes; -1 "
                     + "removes it). The cinema must hold a picture (HUD or Big Screen) for it to show.",
                     parameters: [
                        .boolean("enabled", "wear the remote"),
                        .string("arm", "the arm it is worn on", choices: ["left", "right"]),
                        .number("simulatedAngle", "degrees the made-up forearm's back is turned from the eyes; -1 for none"),
                     ]) { arguments in
                if let enabled = arguments.bool("enabled") { sleeve.isEnabled = enabled }
                if let arm = arguments.string("arm").flatMap(RAVESleeveSide.init(rawValue:)) { sleeve.arm = arm }
                if let angle = arguments.double("simulatedAngle") {
                    sleeve.simulatedAngle = angle < 0 ? nil : Float(angle * .pi / 180)
                }
                return sleeve.status()
            },
            .untyped("cinemaSleevePress", kind: .command,
                     "Presses a tile of the forearm remote as a pinch would (held `seconds`, default 0.05), or moves "
                     + "a slider (media.progress, media.volume) to `fraction`. The remote has to be showing. Read "
                     + "cinemaSleeve, film or the video window's state afterwards.",
                     parameters: [
                        .string("tile", "which tile", required: true, choices: tiles),
                        .number("seconds", "how long it is held, default 0.05"),
                        .number("fraction", "0…1, for the sliders"),
                     ]) { arguments in
                guard sleeve.isVisible else {
                    throw DebugError.failedPrecondition(
                        "the remote is hidden",
                        hint: "put a player in HUD or Big Screen, and in the simulator POST setCinemaSleeve simulatedAngle=0, then wait 0.3 s")
                }
                sleeve.press(try arguments.requireString("tile"),
                             seconds: min(max(arguments.double("seconds") ?? 0.05, 0.01), 5),
                             fraction: arguments.double("fraction").map { Float(min(max($0, 0), 1)) })
                try? await Task.sleep(for: .milliseconds(250))
                return sleeve.status()
            },
        ]
    }
}

#endif
