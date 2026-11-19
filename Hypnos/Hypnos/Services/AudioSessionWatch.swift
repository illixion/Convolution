/*
 Hypnos - why the app's audio was interrupted

 A pause nobody asked for used to take hours to explain (2026-11-19): the
 audio session reported an interruption with reason "default" and nothing
 else, so it read as another app's doing. It was the app's own windows: the
 three generated-model volumes in one room went to the background as the
 wearer walked to the room with the video, and the session was interrupted
 ~170 ms later, every time (five times on the AVP). The system log had the
 clue (RealityKit's scenes tearing down) but nothing tied it to the interruption.

 This watches every scene's activation (by its SwiftUI scene id, which is
 code-defined), which window is key, and the session's interruptions, route
 changes and resets, app-wide, from launch. Each interruption is logged with
 what our own scenes did in the two seconds before it, and the debug query
 `audioSession` returns the session, the scenes and the recent events.

 Such an interruption is undone (`recoverFromOwnInterruption`): the system
 never ends it while the app stays in front. Anchoring the session's spatial
 audio to the playing window (`.scene(identifier:)` instead of `.automatic`)
 was tried first and changed nothing: the session was interrupted all the same.
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

    /// The video windows, to resume the ones that were playing after an interruption our own scenes caused.
    private static let videoWindows = NSHashTable<VideoWindowModel>.weakObjects()

    static func noteVideoWindow(_ window: VideoWindowModel) { videoWindows.add(window) }

    // MARK: - Recording

    /// "gen3d#A926": the SwiftUI scene id and the start of the session's UUID, both app-defined.
    nonisolated private static func sceneLabel(_ scene: UIScene) -> String {
        let id = scene.session.userInfo?["com.apple.SwiftUI.sceneID"] as? String ?? scene.session.role.rawValue
        // "com.example.app:SFBSystemService-6F753290-A212-…": the UUID follows the first dash.
        let identifier = scene.session.persistentIdentifier
        let uuid = identifier.split(separator: "-").dropFirst().first ?? Substring(identifier)
        return "\(id)#\(uuid.prefix(4))"
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
        // Our own: a scene of ours left within a second and one is still in front.
        let ownScenesLeft = sceneChanges.contains {
            now.timeIntervalSince($0.time) < 1 && ["background", "disconnected"].contains($0.state)
        }
        if ownScenesLeft, !foregroundScenes().isEmpty { recoverFromOwnInterruption() }
    }

    /// visionOS interrupts the app's session when some of its own windows go to
    /// the background (generated-model volumes left in another room, 2026-11-19),
    /// whatever the session's anchor, and never ends that interruption while the
    /// app stays in front. So the session is made active again and every video
    /// window that was playing plays on. The players' own pause from the
    /// interruption lands a few milliseconds after this notification, so which
    /// windows were playing is read now and they are resumed a moment later.
    private static func recoverFromOwnInterruption() {
        let playing = videoWindows.allObjects.filter { !$0.isPaused }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                record("couldn't reactivate the session after our own interruption: \(error.logCode)")
                logger.error("Audio session: couldn't reactivate after our own interruption: \(error.logCode, privacy: .public)")
                return
            }
            for window in playing where window.isPaused { window.playCommand?() }
            record("session reactivated after our own interruption, resumed \(playing.count) video window(s)")
            logger.notice("Audio session reactivated after an interruption our own scenes caused; resumed \(playing.count, privacy: .public) video window(s)")
        }
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

    /// The session's spatial audio experience, e.g. "automatic" for `.headTracked(.automatic)`.
    private static func anchorDescription() -> String {
        #if os(visionOS)
        let experience = String(describing: AVAudioSession.sharedInstance().intendedSpatialExperience)
        if experience.contains("automatic") { return "automatic" }
        if experience.contains("scene") { return "a scene" }
        return experience.components(separatedBy: "(").first ?? experience
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
            scenes: UIApplication.shared.connectedScenes.map { Snapshot.Scene(scene: sceneLabel($0), state: states[$0.activationState] ?? "?") },
            events: events.map { Snapshot.Event(time: formatter.string(from: $0.time), event: $0.text) })
    }
}

#endif
