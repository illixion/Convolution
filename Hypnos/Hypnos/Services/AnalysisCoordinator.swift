import DebugTrace
import Foundation
import RAVECompanion
import RAVEMedia

/// A Vergence analysis coordinator (`vergenced`): a service on the home
/// server or a desktop that hands a title's analysis to worker machines in
/// 2 s pieces and serves the results while they are made, nearest the
/// playhead first (`docs/plans/analysis-workers.md`). Convolution tells it
/// where it is playing and reads 10 s chunks, partial ones included, so a
/// 3D title's Smooth Motion fields arrive while it plays instead of after a
/// night's analysis.
///
/// Two ways to reach it, set in Settings: **paired** (`AnalysisPairing`: the
/// API over TLS-PSK on port 8421, keyed from the pairing, nothing secret on
/// the wire), which wins when present, or an **address and token** (plain
/// HTTP, the token in the Keychain). It knows Jellyfin items by their id, as
/// the Library does.
struct AnalysisCoordinator: Sendable {
    enum Transport: Sendable {
        case http(baseURL: URL, token: String)
        case paired(RAVECompanionHTTPClient)
    }

    let transport: Transport
    /// This device among the coordinator's players.
    let player: String

    static let urlKey = "analysisCoordinatorURL"
    static let playerKey = "analysisCoordinatorPlayer"
    static let smoothMotion3D = "smooth-motion-3d"
    /// Smooth Motion for a 2D title (flat or AI 3D): the whole picture's flow,
    /// RIFE at 960×576 on a worker.
    static let smoothMotion2D = "smooth-motion-2d"
    /// AI 3D's depth for a 2D title, made by the offline pipeline with a
    /// larger model than the headset runs (`AnalysisDepthTrack`).
    static let aiDepth = "ai-3d-depth"
    /// AI HDR for an SDR title: a gain grid per frame (`GainGridPlayback`).
    static let aiHDR = "ai-hdr"

    /// The configured coordinator, or nil when there is none.
    static func current() -> AnalysisCoordinator? {
        if let client = AnalysisPairing.client() {
            return AnalysisCoordinator(transport: .paired(client), player: playerID())
        }
        guard let text = UserDefaults.standard.string(forKey: urlKey)?.trimmingCharacters(in: .whitespaces),
              !text.isEmpty, let url = URL(string: text), url.scheme == "http" || url.scheme == "https",
              let token = KeychainStore.string(for: .analysisCoordinatorToken), !token.isEmpty else { return nil }
        return AnalysisCoordinator(transport: .http(baseURL: url, token: token), player: playerID())
    }

    private static func playerID() -> String {
        if let id = UserDefaults.standard.string(forKey: playerKey) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: playerKey)
        return id
    }

    /// What the coordinator says about a title.
    struct Status: Decodable, Sendable {
        let state: String
        let chunkSeconds: Double
        let chunks: Int
        let frameRate: Double
        let piecesDone: Int
        let pieces: Int
    }

    enum Failure: Error {
        case http(Int)
        /// None of the chunk is ready yet.
        case notReady
    }

    /// A response, whichever way it came.
    struct Reply: Sendable {
        let status: Int
        /// Header names lowercased.
        let headers: [String: String]
        let body: Data
    }

    /// One request; `path` has no leading slash.
    func send(_ method: String, _ path: String, json: [String: any Sendable]? = nil) async throws -> Reply {
        let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
        switch transport {
        case .paired(let client):
            let headers = body == nil ? [:] : ["Content-Type": "application/json"]
            let response = try await client.send(method, "/" + path, headers: headers, body: body)
            return Reply(status: response.status, headers: response.headers, body: response.body)
        case .http(let baseURL, let token):
            var request = URLRequest(url: baseURL.appending(path: path))
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 15
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            for (name, value) in http?.allHeaderFields ?? [:] {
                if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
            }
            return Reply(status: http?.statusCode ?? -1, headers: headers, body: data)
        }
    }

    /// Says where this device is playing a Jellyfin item, which queues the
    /// title (described by the coordinator from the server) and puts the
    /// pieces around `seconds` first. Throws for a title it won't work on
    /// (not stereo, a disc, a server it doesn't know).
    @discardableResult
    func playing(itemId: String, seconds: Double, rate: Double = 1,
                 workload: String = smoothMotion3D) async throws -> Status {
        let reply = try await send("POST", "v1/playing", json: [
            "server": "jellyfin", "id": itemId, "workload": workload,
            "seconds": max(seconds, 0), "rate": rate, "player": playerName(for: workload),
        ])
        guard reply.status == 200 else { throw Failure.http(reply.status) }
        return try JSONDecoder().decode(Status.self, from: reply.body)
    }

    /// This device stopped playing `workload`'s title.
    func stopped(workload: String = smoothMotion3D) async {
        _ = try? await send("POST", "v1/playing", json: [
            "server": "jellyfin", "id": "", "seconds": 0, "player": playerName(for: workload), "stopped": true,
        ])
    }

    /// The coordinator keeps one playhead per player name, and AI 3D plays one
    /// title with several workloads at once (fields, depth, gain grids), so each
    /// reports under its own name; otherwise one would overwrite or stop the
    /// others. The Quest port names them the same way.
    private func playerName(for workload: String) -> String { "\(player)/\(workload)" }

    /// Whether the coordinator answers and lets this device play (a check for Settings).
    func check() async throws -> Bool {
        let reply = try await send("GET", "v1/titles/jellyfin/check/\(Self.smoothMotion3D)")
        return reply.status == 404 || reply.status == 200
    }

    /// Chunk `index` of an item's track for `workload`, whole or not.
    func chunk(itemId: String, index: Int, workload: String = smoothMotion3D) async throws -> StreamingAnalysisChunk {
        let reply = try await send("GET", "v1/titles/jellyfin/\(itemId)/\(workload)/chunks/\(index)")
        switch reply.status {
        case 200:
            return StreamingAnalysisChunk(data: reply.body, isComplete: reply.headers["vergence-chunk-complete"] != "false")
        case 404: throw Failure.notReady
        case let status: throw Failure.http(status)
        }
    }
}

/// Tells the coordinator where the player is, from the playheads the field
/// lookup hears every frame: every few seconds while playing, at once after
/// a seek, and that it stopped when the track is let go.
final class AnalysisPlayheadReporter: @unchecked Sendable {
    private let coordinator: AnalysisCoordinator
    private let itemId: String
    private let workload: String
    private let lock = NSLock()
    private var lastSent: (seconds: Double, at: Date)?
    private var sending = false
    /// How often a steady playhead is reported (the coordinator forgets one after 20 s).
    private static let interval: TimeInterval = 5
    /// A playhead this far from where the last report says it should be is a seek.
    private static let seekSeconds = 3.0

    init(coordinator: AnalysisCoordinator, itemId: String, workload: String = AnalysisCoordinator.smoothMotion3D,
         startSeconds: Double) {
        self.coordinator = coordinator
        self.itemId = itemId
        self.workload = workload
        lastSent = (startSeconds, Date())
    }

    deinit {
        let coordinator = coordinator, workload = workload
        Task.detached(priority: .utility) { await coordinator.stopped(workload: workload) }
    }

    /// Called on the player's thread for every frame; sends only now and then.
    func note(_ seconds: Double) {
        lock.lock()
        let now = Date()
        var due = true
        if let last = lastSent {
            let elapsed = now.timeIntervalSince(last.at)
            let expected = last.seconds + elapsed
            due = elapsed >= Self.interval || abs(seconds - expected) > Self.seekSeconds
        }
        guard due, !sending else { lock.unlock(); return }
        sending = true
        lastSent = (seconds, now)
        lock.unlock()
        let coordinator = coordinator, itemId = itemId, workload = workload
        Task.detached(priority: .utility) { [weak self] in
            do {
                try await coordinator.playing(itemId: itemId, seconds: seconds, workload: workload)
            } catch {
                AppLogger.filmPlayer.info("Smooth Motion: the analysis server didn't take the playhead (\(error.logCode, privacy: .public))")
            }
            self?.finishedSending()
        }
    }

    private func finishedSending() {
        lock.lock()
        sending = false
        lock.unlock()
    }
}
