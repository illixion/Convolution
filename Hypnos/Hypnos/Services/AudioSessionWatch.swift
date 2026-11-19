/*
 Hypnos - why the app's audio was interrupted

 A pause nobody asked for used to take hours to explain (2026-11-19): the
 audio session reported an interruption with reason "default" and nothing
 else, so it read as another app's doing. It was the app's own windows: the
 three generated-model volumes in one room went to the background as the
 wearer walked to the room with the video, and the session was interrupted
 ~170 ms later, both times it was caught. The system log had the clue
 (RealityKit's scenes tearing down) but nothing tied it to the interruption.

 This watches every scene's activation (by its SwiftUI scene id, which is
 code-defined), which window is key, and the session's interruptions, route
 changes and resets, app-wide, from launch. Each interruption is logged with
 what our own scenes did in the two seconds before it, and the debug query
 `audioSession` returns the session, the scenes and the recent events.

 It also holds the session's spatial anchor (visionOS). Left `.automatic`, the
 system picks the scene the app's audio belongs to; the suspicion is that it
 picks whichever window is key when the session activates, which may be a
 volume in another room, and that the session is interrupted when that scene
 leaves. `anchor(to:)` names the window that is playing instead.
 */

#if os(visionOS) || os(iOS)

import AVFoundation
import DebugTrace
import UIKit

@MainActor
enum AudioSessionWatch {
    private static let logger = DebugLogger(subsystem: AppLogger.subsystem, category: "AudioSession")
    private static var observers: [NSObjectProtocol] = []
    private static var events: [(time: Date, text: String)] = []
    private static var sceneChanges: [(time: Date, scene: String, state: String)] = []
    /// The scene the session's sound is anchored to (`anchor(to:)`), by persistent id.
    private(set) static var anchoredScene: String?
    /// Whether `anchor(to:)` sets the session's anchor; off leaves it `.automatic`.
    static var anchorsToPlayingScene = true

    static func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let sceneStates: [(Notification.Name, String)] = [
            (UIScene.willConnectNotification, "connected"),
            (UIScene.didActivateNotification, "active"),
            (UIScene.willDeactivateNotification, "inactive"),
            (UIScene.didEnterBackgroundNotification, "background"),
            (UIScene.willEnterForegroundNotification, "foreground"),
            (UIScene.didDisconnectNotification, "disconnected"),
        ]
        for (name, state) in sceneStates {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let scene = note.object as? UIScene else { return }
                let label = sceneLabel(scene)
                MainActor.assumeIsolated { noteScene(label, state) }
            })
        }
        observers.append(center.addObserver(forName: UIWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            let label = (note.object as? UIWindow)?.windowScene.map(sceneLabel) ?? "?"
            MainActor.assumeIsolated { record("key window: \(label)") }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let reason = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated { noteInterruption(type: type, reason: reason, options: options) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 99
            MainActor.assumeIsolated { record("route change, reason \(reason)") }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                record("media services were reset")
                logger.notice("Audio media services were reset")
            }
        })
        DebugSurface.shared.register([
            .query("audioSession", "The app's audio session (category, options, spatial anchor, other audio), every scene "
                   + "by SwiftUI scene id with its state, and the last 60 session and scene events (interruptions with "
                   + "what our scenes did just before). No titles or URLs.") { _ in snapshot() },
        ])
    }

    /// Anchors the session's sound to the window that is playing (visionOS), so
    /// it never belongs to a window in another room. Call when playback starts.
    static func anchor(to sceneIdentifier: String?) {
        #if os(visionOS)
        guard anchorsToPlayingScene, let sceneIdentifier, sceneIdentifier != anchoredScene else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setIntendedSpatialExperience(.headTracked(soundStageSize: .automatic,
                                                                  anchoringStrategy: .scene(identifier: sceneIdentifier)))
            anchoredScene = sceneIdentifier
            let label = UIApplication.shared.connectedScenes
                .first { $0.session.persistentIdentifier == sceneIdentifier }.map(sceneLabel) ?? "gone"
            record("anchored to \(label)")
            logger.info("Audio session anchored to scene \(label, privacy: .public)")
        } catch {
            logger.error("Couldn't anchor the audio session to its scene: \(error.logCode, privacy: .public)")
        }
        #endif
    }

    /// Each video window's scene, so its model can anchor the session when it starts playing.
    private static let windowScenes = NSMapTable<AnyObject, NSString>.weakToStrongObjects()

    static func noteScene(_ sceneIdentifier: String?, for window: AnyObject) {
        if let sceneIdentifier { windowScenes.setObject(sceneIdentifier as NSString, forKey: window) }
    }

    /// A video window began playing: its scene becomes the session's anchor.
    static func playbackStarted(in window: AnyObject) {
        anchor(to: windowScenes.object(forKey: window) as String?)
    }

    // MARK: - Recording

    /// "gen3d#A926": the SwiftUI scene id and the start of the session's id, both app-defined.
    nonisolated private static func sceneLabel(_ scene: UIScene) -> String {
        let id = scene.session.userInfo?["com.apple.SwiftUI.sceneID"] as? String ?? scene.session.role.rawValue
        return "\(id)#\(scene.session.persistentIdentifier.prefix(4))"
    }

    private static func noteScene(_ label: String, _ state: String) {
        sceneChanges.append((Date(), label, state))
        if sceneChanges.count > 40 { sceneChanges.removeFirst(sceneChanges.count - 40) }
        record("\(label) \(state)")
    }

    private static func record(_ text: String) {
        events.append((Date(), text))
        if events.count > 60 { events.removeFirst(events.count - 60) }
    }

    private static func noteInterruption(type: UInt?, reason: UInt?, options: UInt?) {
        guard type == AVAudioSession.InterruptionType.began.rawValue else {
            let resume = options.map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? false
            record("interruption ended\(resume ? ", may resume" : "")")
            logger.info("Audio session interruption ended\(resume ? " (may resume)" : "", privacy: .public)")
            return
        }
        let now = Date()
        let left = sceneChanges.filter {
            now.timeIntervalSince($0.time) < 2 && ["inactive", "background", "disconnected"].contains($0.state)
        }.map { "\($0.scene) \($0.state) \(Int(now.timeIntervalSince($0.time) * 1000)) ms before" }
        let cause = left.isEmpty
            ? "none of our scenes left in the 2 s before (another app or the system)"
            : "after our own scenes left: \(left.joined(separator: ", "))"
        let session = AVAudioSession.sharedInstance()
        let summary = "interruption began, reason \(reasonName(reason)), \(cause); foreground [\(foregroundScenes())], "
            + "anchor \(anchorDescription()), other audio \(session.isOtherAudioPlaying)"
        record(summary)
        logger.notice("Audio session \(summary, privacy: .public)")
    }

    private static func reasonName(_ raw: UInt?) -> String {
        switch raw {
        case nil: return "none"
        case 0: return "default"
        case 1: return "app suspended"
        case 2: return "built-in mic muted"
        case 3: return "route disconnected"
        case let other?: return "\(other)"
        }
    }

    private static func foregroundScenes() -> String {
        UIApplication.shared.connectedScenes
            .filter { $0.activationState == .foregroundActive }
            .map(sceneLabel).sorted().joined(separator: ", ")
    }

    private static func anchorDescription() -> String {
        #if os(visionOS)
        let experience = AVAudioSession.sharedInstance().intendedSpatialExperience
        guard let anchoredScene, String(describing: experience).contains("scene") else {
            return String(describing: experience).contains("automatic") ? "automatic" : "\(type(of: experience))"
        }
        return UIApplication.shared.connectedScenes
            .first { $0.session.persistentIdentifier == anchoredScene }.map(sceneLabel) ?? "a scene that is gone"
        #else
        return "n/a"
        #endif
    }

    struct Snapshot: Encodable {
        struct Scene: Encodable { let scene: String; let state: String }
        struct Event: Encodable { let time: String; let event: String }
        let category: String
        let mode: String
        let mixesWithOthers: Bool
        let otherAudioPlaying: Bool
        let anchor: String
        let anchorsToPlayingScene: Bool
        let scenes: [Scene]
        let events: [Event]
    }

    private static func snapshot() -> Snapshot {
        let session = AVAudioSession.sharedInstance()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let states: [UIScene.ActivationState: String] = [.foregroundActive: "active", .foregroundInactive: "inactive",
                                                        .background: "background", .unattached: "unattached"]
        return Snapshot(
            category: session.category.rawValue,
            mode: session.mode.rawValue,
            mixesWithOthers: session.categoryOptions.contains(.mixWithOthers),
            otherAudioPlaying: session.isOtherAudioPlaying,
            anchor: anchorDescription(),
            anchorsToPlayingScene: anchorsToPlayingScene,
            scenes: UIApplication.shared.connectedScenes.map { Snapshot.Scene(scene: sceneLabel($0), state: states[$0.activationState] ?? "?") },
            events: events.map { Snapshot.Event(time: formatter.string(from: $0.time), event: $0.text) })
    }
}

#endif
