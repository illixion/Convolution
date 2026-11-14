//
//  ForearmSleeve.swift
//  Hypnos
//
//  The remote worn on the forearm in the app's immersive spaces: RAVE Engine's `RAVESleeve`,
//  drawn by `RAVEPanel` and worn through `RAVESleeveWearer`, on the back of the forearm, shown
//  while that face is turned to the eyes and pressed with the other index finger or by looking
//  and pinching.
//
//  This is the one driver: the setting and the arm, the hands (a session of its own, or a host's
//  in Nexus), the head, joining whichever space is open and stepping the sleeve every frame.
//  What is on the arm is a `SleeveRemote`: the cinema's media remote (`CinemaRemote`, HUD and Big
//  Screen) or the photo viewer's (`PhotoSleeveRemote`, the photo HUD). One copy of this glue,
//  not one per space (the portfolio's rule: a second copy is the trigger to share).
//
//  Without hands there is no sleeve and nothing else changes.
//

#if os(visionOS)

import ARKit
import Combine
import DebugTrace
import Observation
import QuartzCore
import RAVEPanel
import RealityKit
import simd
import SwiftUI

/// What a space puts on the arm.
@MainActor
protocol SleeveRemote: AnyObject {
    /// For status and the debug server: "cinema", "photo".
    var kind: String { get }
    var layout: RAVESleeveLayout { get }
    /// It has something to drive now (a picture in the space). The sleeve
    /// shows only then.
    var isActive: Bool { get }
    /// Keeps the tiles' state current; called every frame before the sleeve steps.
    func refresh(_ wearer: RAVESleeveWearer)
    /// What the wearer did.
    func handle(_ event: RAVESleeveEvent, _ wearer: RAVESleeveWearer)
    /// After the frame's events: where a remote applies a drag once it is let go.
    func stepped(_ wearer: RAVESleeveWearer)
    /// The space closed: drop what was pending.
    func released()
}

extension SleeveRemote {
    func stepped(_ wearer: RAVESleeveWearer) {}
    func released() {}

    /// Sets a tile's state, sending it to the renderer only when it changed.
    func set(_ wearer: RAVESleeveWearer, _ id: String, _ state: RAVESleeveTileState) {
        if wearer.sleeve.states[id] != state { wearer.sleeve.states[id] = state }
    }
}

@MainActor
@Observable
final class ForearmSleeve {
    static let shared = ForearmSleeve()

    // The keys predate the photo HUD: the setting was the cinema's first.
    private static let enabledKey = "cinema.sleeve.enabled"
    private static let armKey = "cinema.sleeve.arm"

    /// Wear the remote in the spaces that offer one.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            HypnosDefaults.store.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                if remote != nil { startHands() }
            } else {
                // The tiles fade from `tick`, which keeps stepping while the space is open.
                stopHands()
                remote?.released()
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
    /// (`CinemaSpace.hidesUpperLimbs`; the photo HUD's space always does).
    private(set) var isVisible = false
    /// Why there is no sleeve, for Settings: nil while hands are tracked.
    private(set) var handsStatus: String?

    /// The hands of a host that owns the space and its ARKit session (Nexus); nil in
    /// this app's own spaces, where the sleeve runs hand tracking itself.
    @ObservationIgnored var hostHands: (@MainActor () -> (left: HandAnchor?, right: HandAnchor?)?)?
    /// A made-up arm for the simulator, which has no hands: the angle (radians) the
    /// back of the forearm is turned from the eyes. Set by the debug server.
    @ObservationIgnored var simulatedAngle: Float?

    /// The remote of the space that is open, and the wearer for its layout.
    @ObservationIgnored private(set) var remote: (any SleeveRemote)?
    @ObservationIgnored private(set) var wearer: RAVESleeveWearer?
    /// One wearer per kind of remote, kept between openings (its tiles are built once).
    @ObservationIgnored private var wearers: [String: RAVESleeveWearer] = [:]
    /// The space's own head pose (the cinema tracks the head anyway); nil to use the
    /// sleeve's own world tracking.
    @ObservationIgnored private var spaceHeadPose: (@MainActor () -> simd_float4x4?)?
    @ObservationIgnored private var root: Entity?
    @ObservationIgnored private var attachRetry: Task<Void, Never>?

    @ObservationIgnored private var handSession: ARKitSession?
    @ObservationIgnored private var handFeed: RAVESleeveHandFeed?
    @ObservationIgnored private var worldTracking: WorldTrackingProvider?
    @ObservationIgnored private var subscription: (any Cancellable)?
    @ObservationIgnored private weak var subscribedScene: RealityKit.Scene?

    private let logger = DebugLogger(subsystem: "com.illixion.hypnos", category: "Sleeve")

    private init() {
        let store = HypnosDefaults.store
        isEnabled = store.object(forKey: Self.enabledKey) == nil ? true : store.bool(forKey: Self.enabledKey)
        arm = store.string(forKey: Self.armKey).flatMap(RAVESleeveSide.init(rawValue:)) ?? .left
    }

    // MARK: The space

    /// A space opened with `remote` on offer. `headPose` is the space's own, if it
    /// tracks the head; otherwise the sleeve does. Call `attach(to:)` with the root
    /// the tiles go under.
    func spaceOpened(_ remote: any SleeveRemote, headPose: (@MainActor () -> simd_float4x4?)? = nil) {
        if let previous = self.remote, previous !== remote { closeCurrent() }
        self.remote = remote
        spaceHeadPose = headPose
        let wearer = wearers[remote.kind] ?? RAVESleeveWearer(layout: remote.layout)
        wearers[remote.kind] = wearer
        self.wearer = wearer
        if isEnabled { startHands() }
    }

    /// Puts the tiles under `root` and steps the sleeve on every scene update. Safe to
    /// call every frame (the cinema does); a root without a scene yet is retried.
    func attach(to root: Entity) {
        guard let wearer else { return }
        self.root = root
        if wearer.root.parent !== root { root.addChild(wearer.root) }
        guard let scene = root.scene else {
            scheduleAttachRetry()
            return
        }
        attachRetry?.cancel()
        attachRetry = nil
        guard scene !== subscribedScene else { return }
        subscription?.cancel()
        subscribedScene = scene
        subscription = scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// The space closed.
    func spaceClosed() {
        closeCurrent()
    }

    private func closeCurrent() {
        stopHands()
        subscription?.cancel()
        subscription = nil
        subscribedScene = nil
        attachRetry?.cancel()
        attachRetry = nil
        remote?.released()
        wearer?.release()
        wearer?.root.removeFromParent()
        remote = nil
        wearer = nil
        root = nil
        spaceHeadPose = nil
        isVisible = false
    }

    private func scheduleAttachRetry() {
        guard attachRetry == nil else { return }
        attachRetry = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, let root = self.root else { return }
                if root.scene != nil {
                    self.attachRetry = nil
                    self.attach(to: root)
                    return
                }
            }
        }
    }

    // MARK: Hands and head

    private func startHands() {
        guard hostHands == nil, handSession == nil else { return }
        guard HandTrackingProvider.isSupported else {
            handsStatus = "Hand tracking isn't available here"
            return
        }
        let session = ARKitSession()
        let feed = RAVESleeveHandFeed()
        // The cinema tracks the head itself; the photo HUD's space doesn't.
        let world = spaceHeadPose == nil ? WorldTrackingProvider() : nil
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
                try await session.run([feed.provider] + (world.map { [$0] } ?? []))
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
            self.worldTracking = world
            self.handsStatus = nil
            self.logger.info("Sleeve: hand tracking running, worn on the \(self.arm.rawValue, privacy: .public) arm")
        }
    }

    private func stopHands() {
        handFeed?.stop()
        handFeed = nil
        handSession?.stop()
        handSession = nil
        worldTracking = nil
        handsStatus = nil
    }

    private func headPose() -> simd_float4x4? {
        if let spaceHeadPose { return spaceHeadPose() }
        guard let tracking = worldTracking, tracking.state == .running,
              let anchor = tracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()),
              anchor.isTracked else { return nil }
        return anchor.originFromAnchorTransform
    }

    // MARK: Per frame

    private func tick() {
        guard let remote, let wearer else { return }
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
        let allowed = remote.isActive
        remote.refresh(wearer)

        let device = headPose()
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
        for event in events { remote.handle(event, wearer) }
        remote.stepped(wearer)
        if wearer.isVisible != isVisible { isVisible = wearer.isVisible }
    }

    // MARK: Debug

    func status() -> [String: Any] {
        var out = wearer?.status() ?? [:]
        out["enabled"] = isEnabled
        out["arm"] = arm.rawValue
        out["remote"] = remote?.kind ?? "none"
        out["active"] = remote?.isActive ?? false
        out["hands"] = handsStatus ?? (hostHands != nil ? "host" : (handFeed != nil ? "running" : "off"))
        out["head"] = spaceHeadPose != nil ? "space" : (worldTracking != nil ? "own" : "none")
        if let simulatedAngle { out["simulatedAngleDegrees"] = Double(simulatedAngle * 180 / .pi) }
        return out
    }

    /// The tiles the remote on the arm has, for the debug server.
    var tileIDs: [String] { remote?.layout.allTiles.map(\.tile.id) ?? [] }

    /// The debug server's press: a tile by id, as a pinch would; a slider goes to
    /// `fraction`.
    func press(_ tile: String, seconds: Double, fraction: Float?) {
        guard let wearer else { return }
        if let fraction {
            wearer.sleeve.pressBegan(tile, now: CACurrentMediaTime(), source: .remote)
            wearer.sleeve.setValue(tile, fraction: fraction, source: .remote)
            wearer.sleeve.pressEnded(tile, now: CACurrentMediaTime())
        } else {
            wearer.press(tile, seconds: seconds)
        }
    }
}

// MARK: - Settings

/// Sound and Picture's Cinema section: the remote on the forearm, in the cinema and the photo HUD.
struct ForearmSleeveSettings: View {
    @Bindable private var sleeve = ForearmSleeve.shared

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
             ?? "In HUD and Big Screen, turn the back of your forearm toward you for play, seek, skip and volume; in a photo's HUD, for the next picture, 3D and adjustments. Press a tile with your other index finger, or look at it and pinch.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Debug endpoints

@MainActor
enum ForearmSleeveEndpoints {
    static var all: [DebugEndpoint] {
        let sleeve = ForearmSleeve.shared
        return [
            .untyped("sleeve", kind: .query,
                     "The remote worn on the forearm: which space's remote is on (cinema: HUD and Big Screen; photo: "
                     + "a photo's HUD), enabled, which arm, whether hands are tracked (or why not), where the head "
                     + "comes from, whether it shows, how steadied it is, and each tile's place and state.") { _ in
                sleeve.status()
            },
            .untyped("setSleeve", kind: .command,
                     "Sets the forearm remote: `enabled`, `arm` (left or right), and for the simulator, which has no "
                     + "hands, `simulatedAngle` in degrees (0 turns the back of a made-up forearm to the eyes; -1 "
                     + "removes it). A space with a remote must be open (a player in HUD or Big Screen, or a photo "
                     + "in HUD) for it to show.",
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
            .untyped("sleevePress", kind: .command,
                     "Presses a tile of the forearm remote as a pinch would (held `seconds`, default 0.05), or moves "
                     + "a slider to `fraction`. The remote has to be showing; `sleeve` lists the tiles of the one on. "
                     + "Read `sleeve`, `film`, the video window's or the photo window's state afterwards.",
                     parameters: [
                        .string("tile", "which tile, e.g. media.playPause or photo.next", required: true),
                        .number("seconds", "how long it is held, default 0.05"),
                        .number("fraction", "0…1, for the sliders"),
                     ]) { arguments in
                guard sleeve.isVisible else {
                    throw DebugError.failedPrecondition(
                        "the remote is hidden",
                        hint: "put a player in HUD or Big Screen, or a photo in HUD, and in the simulator POST setSleeve simulatedAngle=0, then wait 0.3 s")
                }
                let tile = try arguments.requireString("tile")
                guard sleeve.tileIDs.contains(tile) else {
                    throw DebugError.invalidArgument(
                        "no tile \(tile) on this remote",
                        hint: "one of " + sleeve.tileIDs.joined(separator: ", "))
                }
                sleeve.press(tile,
                             seconds: min(max(arguments.double("seconds") ?? 0.05, 0.01), 5),
                             fraction: arguments.double("fraction").map { Float(min(max($0, 0), 1)) })
                try? await Task.sleep(for: .milliseconds(250))
                return sleeve.status()
            },
        ]
    }
}

#endif
