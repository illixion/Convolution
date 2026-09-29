/*
 Hypnos - Remote WebSocket Client

 Real-time control, sensor data, and cross-device synchronization with the
 RoboFrame server.

 The connection-management core — ephemeral session, exponential backoff,
 keepalive, NWPathMonitor wake, probe-on-wake, suspend/revive — now lives in
 `RAVEWebSocketTransport`, shared with Spatial Home's Home Assistant client
 (which adapted most of it from here in the first place, then drifted).

 What stays here is everything RoboFrame-shaped: the `{action, payload}`
 framing, session multiplexing, the presence/visibility scene state machine,
 and the replay that has to happen after every reconnect. In particular
 **readiness is declared from here**, on the first inbound frame — the
 transport has no opinion about when a socket becomes usable, because Spatial
 Home promotes on a parsed `auth_ok` instead.
 */

import DebugTrace
import Foundation
import RAVENet

struct HASensorReading: Identifiable {
    let entityId: String
    var state: String
    var friendlyName: String
    var unitOfMeasurement: String
    var isUnavailable: Bool = false
    var lastKnownState: String?

    var id: String { entityId }

    var displayEmoji: String {
        let name = friendlyName.lowercased()
        if name.contains("temperature") { return "\u{1F321}\u{FE0F}" }
        if name.contains("humidity") { return "\u{1F4A7}" }
        if name.contains("pressure") { return "\u{1F32C}\u{FE0F}" }
        if name.contains("co2") || name.contains("carbon") { return "\u{2601}\u{FE0F}" }
        return ""
    }
}

enum RemoteWSMessage {
    case tagLists(lists: [[String]])
    case currentTagList(index: Int)
    case showText(text: String, bgColorHex: String, imageUrl: String?)
    case dismissText
    case playAudio(url: URL)
    case stopAudio
    case sensorUpdate(entityId: String, state: String, friendlyName: String, unit: String)
    case refresh
    /// Server → client playback channel state. The orchestrator pushes this
    /// on every channel change (advance, displaySync claim, tag list change,
    /// mod-tag change). Payload shape:
    ///   { deviceId: String, mergeDriver: String?, interval: Int (ms),
    ///     currentList: Int, modTags: [String],
    ///     current: { id: Int, ext: String }?, next: { id: Int, ext: String }?,
    ///     upcoming: [{ id: Int, ext: String }] }
    case playback(payload: [String: Any])
    /// Server rejected the upgrade with close code 1008 (policy violation).
    /// Emitted once; reconnects are halted until the next explicit connect.
    case fatalAuthError(reason: String)
    /// Channel-scoped notification fired when a refill returned zero rows
    /// for a non-empty tag query (typo'd `setModTags`, unsatisfiable combo).
    /// Informational only — the slideshow stays on its current image.
    case searchEmpty(query: String)
    /// HA-driven panel power for a target deviceId (`displayState` frames,
    /// also rebroadcast from a node-display's `reportDisplay`). Only frames
    /// carrying a real `state` are surfaced — a state-less frame must not
    /// toggle anything. Sessions filter on their own deviceId.
    case displayState(target: String, on: Bool)
}

/// One logical viewer session multiplexed onto a shared connection.
/// Per-session onMessage receives `playback` frames addressed to this
/// sessionId plus all connection-wide frames (tagLists, currentTagList,
/// sensors, effect frames). onConnected fires after the underlying
/// connection produces its first inbound frame on every (re)connection
/// — replay slideshowConfig from there.
@MainActor
final class RemoteWSSessionHandlers {
    var onMessage: ((RemoteWSMessage) -> Void)?
    var onConnected: (() -> Void)?
}

@MainActor
@Observable
class RemoteWebSocketClient {
    var sensorData: [String: HASensorReading] = [:]

    /// Mirrors the transport, plus the app-declared promotion to `.ready` on
    /// the first inbound frame.
    private(set) var state: RAVEConnectionState = .idle

    /// True once the socket is actually carrying traffic — not merely upgraded.
    /// An in-progress upgrade can look healthy for a long time before failing,
    /// and consumers (including force-reconnect callers) rely on this meaning
    /// "frames are flowing".
    var isConnected: Bool { state.isReady }

    private var transport: RAVEWebSocketTransport?
    private var eventTask: Task<Void, Never>?
    private var wsURL: URL?

    /// Outgoing frames are funnelled through a stream consumed by one task, so
    /// they reach the transport actor in the order they were produced. Sending
    /// each frame from its own `Task` would leave ordering to the scheduler,
    /// and this protocol is order-sensitive (slideshowConfig must precede the
    /// scene-state replay).
    private var outboundContinuation: AsyncStream<String>.Continuation?
    private var outboundTask: Task<Void, Never>?

    /// Multiplexing — multiple viewer windows can share one underlying
    /// connection, each addressed by a sessionId. `playback` frames carry
    /// a `sessionIds` array and are routed to matching entries here;
    /// connection-wide frames (tagLists, sensors, effects) fan out to
    /// every entry. Refcount: when the last session detaches, the
    /// connection is torn down.
    private var sessions: [String: RemoteWSSessionHandlers] = [:]

    /// Attach a logical viewer session to this connection. The connection
    /// is established lazily on the first attach. Returns the handlers
    /// record so the caller can wire its onMessage/onConnected closures.
    /// `wsEndpoint` is honored only on the first attach; subsequent
    /// attaches reuse the existing connection regardless of endpoint.
    @discardableResult
    func attachSession(sessionId: String, wsEndpoint: String) -> RemoteWSSessionHandlers {
        if let existing = sessions[sessionId] { return existing }
        let entry = RemoteWSSessionHandlers()
        sessions[sessionId] = entry

        if wsURL == nil, !wsEndpoint.isEmpty, let url = URL(string: wsEndpoint) {
            connect(to: url)
        } else if isConnected {
            // Connection already alive — fire onConnected for late joiners
            // immediately (after the caller wires the closure; they'll do
            // that synchronously after this returns). Re-check liveness
            // inside the callback: a suspend can run before this block.
            DispatchQueue.main.async { [weak self, weak entry] in
                guard let self else { return }
                guard self.isConnected else {
                    self.reviveIfIdle()
                    return
                }
                entry?.onConnected?()
            }
        } else {
            // The connection exists but is down — almost always a suspend
            // releasing it once every sibling window went absent (the endpoint
            // is retained, so the first branch above doesn't fire either).
            // Attaching used to do nothing at all here: no connect, and no
            // `onConnected`, so a window pinned while the other rooms' windows
            // were away never sent `slideshowConfig`, never got a `playback`
            // frame, and sat on its loading spinner until some unrelated
            // scene-phase edge revived the socket. A new session is its own
            // reason to reconnect.
            reviveIfIdle()
        }
        return entry
    }

    /// Detach a session. Sends a best-effort `sessionEnd` to the server
    /// so the orchestrator can drop the channel binding without waiting
    /// for the channel grace timeout. Returns the number of remaining
    /// attached sessions; zero means the caller should call `disconnect()`
    /// to release the underlying connection.
    @discardableResult
    func detachSession(sessionId: String) -> Int {
        guard sessions.removeValue(forKey: sessionId) != nil else { return sessions.count }
        if isConnected {
            if let contribution = sceneBySession[sessionId] {
                sendJSON([
                    "sessionId": sessionId,
                    "action": "present",
                    "payload": ["deviceId": contribution.deviceId, "present": false],
                ])
            }
            sendJSON(["sessionId": sessionId, "action": "sessionEnd"])
        }
        // Drop this window's presence contribution. If it was the last present
        // source for its deviceId, flushSceneState emits the OFF edge — without
        // it a closed window leaves the shared socket asserting presence for a
        // display that no longer exists, and the channel never parks.
        sceneBySession.removeValue(forKey: sessionId)
        sentPresenceBySession.removeValue(forKey: sessionId)
        if isConnected { flushSceneState() }
        return sessions.count
    }

    var attachedSessionCount: Int { sessions.count }

    private func broadcastToSessions(_ message: RemoteWSMessage) {
        for entry in sessions.values { entry.onMessage?(message) }
    }

    private func routeToSessions(_ message: RemoteWSMessage, sessionIds: [String]) {
        for id in sessionIds {
            sessions[id]?.onMessage?(message)
        }
    }

    // MARK: - Lifecycle

    private func connect(to url: URL) {
        wsURL = url

        let transport = RAVEWebSocketTransport(
            configuration: .init(url: url),
            logger: RAVENetAppLogger(),
            pingFrameProvider: { #"{"action":"ping"}"# },
            failurePolicy: { failure in
                // The broker closes unauthenticated upgrades with 1008
                // (policy violation). Reconnecting won't fix a bad token, so
                // halt the loop and surface the reason once — the app sees it
                // as a `.failed` state change and broadcasts `.fatalAuthError`.
                guard failure.closeCode == .policyViolation else { return .reconnect }
                let reason = failure.closeReason.flatMap { $0.isEmpty ? nil : $0 } ?? "invalid token"
                return .halt("Server rejected WebSocket: \(reason). Check the Access Token in viewer settings.")
            }
        )
        self.transport = transport

        let (outbound, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        outboundContinuation = continuation
        outboundTask = Task {
            for await frame in outbound {
                await transport.send(frame)
            }
        }

        // Inherits this class's main-actor isolation, so `handle` is a direct
        // call — only the stream iteration suspends.
        eventTask = Task { [weak self] in
            for await event in transport.events {
                guard let self else { return }
                self.handle(event)
            }
        }

        Task { await transport.start() }
    }

    func disconnect() {
        eventTask?.cancel()
        eventTask = nil
        outboundContinuation?.finish()
        outboundContinuation = nil
        outboundTask?.cancel()
        outboundTask = nil
        let outgoing = transport
        transport = nil
        wsURL = nil
        Task { await outgoing?.stop() }
        state = .idle
    }

    /// Probe the socket with a JSON ping; if no inbound traffic arrives
    /// within `timeout` seconds, force a reconnect. Use this on
    /// scene-phase wakes instead of unconditionally reconnecting — a
    /// healthy connection answers the ping with a pong (per protocol.md)
    /// and we leave it alone, avoiding spurious displayDisconnect
    /// broadcasts to peer kiosks.
    func probeOrReconnect(timeout: TimeInterval = 3) {
        guard let transport else { return }
        Task { await transport.probeOrReconnect(timeout: timeout) }
    }

    /// Force an immediate reconnect attempt, cancelling any sleeping
    /// backoff. Called by viewers when returning to the foreground so
    /// recovery doesn't have to wait out the exponential delay.
    func forceReconnectNow() {
        guard let transport else { return }
        Task { await transport.forceReconnectNow() }
    }

    /// Bring a released/idle connection back up.
    private func reviveIfIdle() {
        guard let transport else { return }
        Task { await transport.reviveIfIdle() }
    }

    /// Flush anything queued (notably a just-reported `present:false`) and, if
    /// nothing on this connection is present any more, hand the server a clean
    /// close.
    ///
    /// Must be awaited under a background-task assertion or the app suspends
    /// mid-flush and the frames never reach the transport. See
    /// `RAVEWebSocketTransport.flushAndSuspend` for why the trailing frame is
    /// what proves the ones ahead of it went out.
    func flushAndSuspendIfAbsent() async {
        guard let transport else { return }
        await transport.flushAndSuspend { [weak self] in
            // Re-checked after the flush: a window may have come back while we
            // were waiting for it to complete.
            await self?.allSessionsAbsent ?? false
        }
    }

    // MARK: - Transport events

    private func handle(_ event: RAVENetEvent) {
        switch event {
        case .frame(let text):
            if !isConnected { promoteToConnected() }
            handleMessage(text)

        case .stateChanged(let newState):
            // Ignore an echo of the promotion this class already applied.
            guard state != newState else { return }
            state = newState
            if case .failed(let reason) = newState {
                broadcastToSessions(.fatalAuthError(reason: reason))
                AppLogger.remoteViewer.error("WS failed: \(reason)")
            }

        case .failure:
            // Already logged with full diagnostics by the transport, and the
            // reconnect-vs-halt decision came from our own failure policy.
            break
        }
    }

    /// First frame from the upgraded connection. Promote to fully-connected and
    /// notify every attached session so each re-sends `slideshowConfig` — the
    /// server forgets per-session channel binding when a socket dies.
    private func promoteToConnected() {
        // Readiness is ours to declare, so apply it here rather than waiting to
        // hear it back — the replay below sends immediately and `sendJSON`'s
        // callers gate on `isConnected`.
        state = .ready
        if let transport {
            Task { await transport.markReady() }
        }
        for entry in sessions.values { entry.onConnected?() }
        // The server forgot our presence/visibility when the old socket died,
        // so re-state every aggregate. Runs after the sessions' onConnected
        // (slideshowConfig first, per the protocol checklist) and doesn't
        // depend on their debounced re-reports, which would be deduped as
        // unchanged anyway.
        sentPresenceBySession.removeAll()
        sentVisibilityByDevice.removeAll()
        flushSceneState(force: true)
    }

    // MARK: - Scene state (present / visibility)
    //
    // `present` is session-scoped because each window has its own server
    // channel. `visibility` remains device-scoped home-location telemetry, so
    // it is OR-aggregated across windows that share the configured deviceId.

    private struct SceneContribution {
        var deviceId: String
        var present: Bool
        var visible: Bool
    }

    /// Per-session scene state, keyed by sessionId. Retained across reconnects
    /// (the socket dies, the windows don't) so the post-reconnect replay has
    /// real values to send.
    private var sceneBySession: [String: SceneContribution] = [:]
    /// Last state actually put on the wire. Cleared on reconnect because the
    /// server forgets every session binding and scene report with the socket.
    private var sentPresenceBySession: [String: Bool] = [:]
    private var sentVisibilityByDevice: [String: Bool] = [:]

    /// Record this session's scene state and emit changed session/device
    /// edges. `present` drives the slideshow (all-absent → the server
    /// dark-advances one post and parks, so the next arrival sees a fresh
    /// image); `visible` is home-location telemetry for the HA motion sensor.
    func reportSceneState(sessionId: String, deviceId: String, present: Bool, visible: Bool) {
        sceneBySession[sessionId] = SceneContribution(deviceId: deviceId, present: present, visible: visible)
        flushSceneState()
    }

    /// Emit changed session presence and aggregate device visibility. `force`
    /// re-sends everything after a reconnect.
    private func flushSceneState(force: Bool = false) {
        // Nothing reaches a dead socket, and recording these as sent would let
        // the reconnect skip them as unchanged. The reconnect replays every
        // aggregate from scratch, so just keep the contributions and wait —
        // but a session declaring itself present while the socket is down is
        // also a reason to bring it back, not just something to queue behind
        // the next reconnect that happens to fire.
        guard isConnected else {
            if !allSessionsAbsent { reviveIfIdle() }
            return
        }

        var visibility: [String: Bool] = [:]
        for (sessionId, contribution) in sceneBySession {
            if force || sentPresenceBySession[sessionId] != contribution.present {
                sentPresenceBySession[sessionId] = contribution.present
                AppLogger.remoteViewer.info("WS tx present sessionId=\(sessionId, privacy: .private(mask: .hash)) deviceId=\(contribution.deviceId, privacy: .private(mask: .hash)) present=\(contribution.present, privacy: .public)")
                sendJSON([
                    "sessionId": sessionId,
                    "action": "present",
                    "payload": ["deviceId": contribution.deviceId, "present": contribution.present],
                ])
            }
            visibility[contribution.deviceId] = (visibility[contribution.deviceId] ?? false) || contribution.visible
        }

        // A deviceId whose last session detached still needs a visibility OFF
        // edge while the shared socket remains alive.
        for deviceId in sentVisibilityByDevice.keys where visibility[deviceId] == nil {
            visibility[deviceId] = false
        }

        for (deviceId, visible) in visibility where force || sentVisibilityByDevice[deviceId] != visible {
            sentVisibilityByDevice[deviceId] = visible
            AppLogger.remoteViewer.info("WS tx visibility deviceId=\(deviceId, privacy: .private(mask: .hash)) visible=\(visible, privacy: .public)")
            sendJSON(["action": "visibility", "payload": ["deviceId": deviceId, "visible": visible]])
        }

        // Drop bookkeeping for devices that are fully absent and have no
        // sessions left, so the maps don't grow across a long session.
        let live = Set(sceneBySession.values.map(\.deviceId))
        sentVisibilityByDevice = sentVisibilityByDevice.filter { live.contains($0.key) || $0.value }
    }

    /// True when no attached session is present anywhere — i.e. nothing on this
    /// connection is showing a slideshow. Used to decide whether the socket can
    /// be released on background.
    var allSessionsAbsent: Bool {
        !sceneBySession.values.contains(where: { $0.present })
    }

    func sendBlock(postId: Int) {
        sendJSON(["action": "block", "payload": ["id": postId]])
    }

    /// displaySync claims the merge driver role: `enabled: true` makes this
    /// session's channel the source of truth for every channel — every
    /// connected display mirrors the driver's playback regardless of its
    /// own deviceId. `enabled: false` releases the merge.
    func sendDisplaySync(sessionId: String, enabled: Bool) {
        sendJSON(["sessionId": sessionId, "action": "displaySync", "payload": ["enabled": enabled]])
    }

    /// Required after WS open: join the channel identified by this stable
    /// deviceId and sessionId. Mod tags ride along so the orchestrator's first refill
    /// query already includes them — without that the initial query is
    /// discarded when a separate setModTags arrives a few ms later.
    func sendSlideshowConfig(sessionId: String, deviceId: String, interval: Int, bright: Bool, ratio: Double? = nil, modTags: [String] = []) {
        // No width/height: Hypnos fetches at the source resolution
        // (server treats absent dimensions as "no downscale"), so advertising a
        // size would only mis-key the server's prefetch. No convert either — we
        // never ask the server to transcode stills, and under convert it would
        // return animated posts as mp4 sized to those dimensions.
        var payload: [String: Any] = [
            "deviceId": deviceId,
            "interval": interval,
            "bright": bright,
            "modTags": modTags,
        ]
        if let ratio { payload["ratio"] = ratio }
        sendJSON(["sessionId": sessionId, "action": "slideshowConfig", "payload": payload])
    }

    /// Connection-wide device telemetry (gated behind the Console dev toggle).
    /// `reportMetrics` is a periodic memory/state sample; the server stores it
    /// for diagnosing the multi-window slideshow OOM during live playback. Not
    /// part of the slideshow loop — see protocol.md `reportMetrics`.
    func sendReportMetrics(_ metrics: DeviceMetrics) {
        guard isConnected else { return }
        sendJSON(["action": "reportMetrics", "payload": metrics.payload])
    }

    /// Connection-wide event log line (warnings, trims, guard hits). Paired with
    /// `reportMetrics`; see protocol.md `reportLog`.
    func sendReportLog(deviceId: String, app: String, level: String, domain: String, message: String) {
        guard isConnected else { return }
        sendJSON(["action": "reportLog", "payload": [
            "deviceId": deviceId,
            "app": app,
            "level": level,
            "domain": domain,
            "message": message,
            "ts": Int(Date().timeIntervalSince1970 * 1000),
        ]])
    }

    /// Client-supplied modifier tags. The orchestrator folds them into this
    /// channel's DuckDB query (last-write-wins among same-channel sessions).
    func sendSetModTags(sessionId: String, tags: [String]) {
        sendJSON(["sessionId": sessionId, "action": "setModTags", "payload": ["tags": tags]])
    }

    /// Switch the active tag list catalog index for the sender's channel.
    /// Per-channel — the server scopes the change to the deviceId behind
    /// this session, so peer channels keep their own list.
    func sendSetTagList(sessionId: String, listNumber: Int) {
        sendJSON(["sessionId": sessionId, "action": "setTagList", "payload": ["listNumber": listNumber]])
    }

    /// Ask the server to advance the channel. Any session may call this;
    /// when displaySync is active, the merge driver's channel advances.
    func sendRequestNext(sessionId: String) {
        sendJSON(["sessionId": sessionId, "action": "requestNext"])
    }

    /// Ask the server to reshuffle the current channel's post order.
    /// Session-scoped like `requestNext`: the orchestrator resolves the channel
    /// from (ws, sessionId), so this must carry *our* sessionId. Sending the
    /// deviceId here instead made the server's session lookup miss and return
    /// silently — the button did nothing.
    func sendReshuffle(sessionId: String) {
        sendJSON(["sessionId": sessionId, "action": "reshuffle"])
    }

    /// Tell the server we've finished transitioning to `postId`. The
    /// orchestrator's readiness barrier waits for every visible session on
    /// the channel before starting the dwell timer.
    /// `durationMs` is the clip length for a video; the server dwells for
    /// max(interval, durationMs), so a clip longer than the interval delays
    /// the advance until it has played through. Omitted (nil) for images.
    func sendImageReady(sessionId: String, postId: Int, durationMs: Int? = nil) {
        var payload: [String: Any] = ["id": postId]
        if let durationMs, durationMs > 0 { payload["durationMs"] = durationMs }
        sendJSON(["sessionId": sessionId, "action": "imageReady", "payload": payload])
    }

    // MARK: - Private

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else {
            AppLogger.remoteViewer.debug("WS rx (unparseable): \(text.prefix(200))")
            return
        }

        let payload = json["payload"]
        AppLogger.remoteViewer.debug("WS rx action=\(action, privacy: .public)")

        switch action {
        case "tagLists":
            // Server-pushed canonical tag list catalog. Accepts either
            // [[String]] (canonical) or [String] (legacy: space-separated).
            if let nested = payload as? [[String]] {
                broadcastToSessions(.tagLists(lists: nested))
            } else if let flat = payload as? [String] {
                let split = flat.map { $0.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
                broadcastToSessions(.tagLists(lists: split))
            }

        case "currentTagList":
            if let dict = payload as? [String: Any],
               let listNumber = dict["listNumber"] as? Int {
                broadcastToSessions(.currentTagList(index: listNumber))
            }

        case "playVideo", "stopVideo":
            // Video RPC commands are intentionally ignored — they're meant
            // for physical kiosk displays, not visionOS windows.
            break

        case "showText":
            if let dict = payload as? [String: Any],
               let text = dict["text"] as? String {
                let bgColor = dict["bgColorHex"] as? String ?? "#000000"
                let imageUrl = dict["imageUrl"] as? String
                broadcastToSessions(.showText(text: text, bgColorHex: bgColor, imageUrl: imageUrl))
            }

        case "dismissText":
            broadcastToSessions(.dismissText)

        case "playAudio":
            if let dict = payload as? [String: Any],
               let urlStr = dict["url"] as? String,
               let url = URL(string: urlStr) {
                broadcastToSessions(.playAudio(url: url))
            }

        case "stopAudio":
            broadcastToSessions(.stopAudio)

        case "update":
            if let dict = payload as? [String: Any],
               let entity = dict["entity"] as? String,
               let state = dict["state"] as? String {
                let attrs = dict["attributes"] as? [String: Any]
                let friendlyName = attrs?["friendly_name"] as? String ?? entity
                let unit = attrs?["unit_of_measurement"] as? String ?? ""

                if state == "unavailable" {
                    if var existing = sensorData[entity] {
                        existing.isUnavailable = true
                        existing.lastKnownState = existing.state
                        sensorData[entity] = existing
                    }
                } else {
                    sensorData[entity] = HASensorReading(
                        entityId: entity,
                        state: state,
                        friendlyName: friendlyName,
                        unitOfMeasurement: unit
                    )
                }
                broadcastToSessions(.sensorUpdate(entityId: entity, state: state, friendlyName: friendlyName, unit: unit))
            }

        case "refresh":
            broadcastToSessions(.refresh)

        case "playback":
            // Session-scoped: route to the sessionIds the server addressed.
            if let dict = payload as? [String: Any] {
                if let ids = json["sessionIds"] as? [String], !ids.isEmpty {
                    routeToSessions(.playback(payload: dict), sessionIds: ids)
                } else {
                    // Defensive fallback (server shouldn't omit sessionIds,
                    // but if it does, deliver to every session so something
                    // renders).
                    broadcastToSessions(.playback(payload: dict))
                }
            }

        case "searchEmpty":
            let query = (payload as? [String: Any])?["query"] as? String ?? ""
            broadcastToSessions(.searchEmpty(query: query))

        case "displayState":
            // Only act on frames that actually carry a panel `state` — a
            // state-less displayState must not toggle anything (same guard
            // as the web kiosk). `"off"`/false → off; anything else → on.
            if let dict = payload as? [String: Any],
               let target = dict["target"] as? String,
               let state = dict["state"] {
                let off = (state as? String) == "off" || (state as? Bool) == false
                broadcastToSessions(.displayState(target: target, on: !off))
            }

        case "ping":
            // Server-initiated liveness probe. Reply immediately so it
            // doesn't decide we're a dead client.
            sendJSON(["action": "pong"])

        case "pong":
            // Reply to our own keepalive ping. The transport already recorded
            // the liveness; nothing more to do.
            break

        default:
            AppLogger.remoteViewer.debug("Unknown WS action: \(action, privacy: .public)")
        }
    }

    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        outboundContinuation?.yield(text)
    }
}
