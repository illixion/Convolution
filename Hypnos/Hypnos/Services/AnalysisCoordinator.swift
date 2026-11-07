import DebugTrace
import Foundation
import RAVEMedia

/// A Vergence analysis coordinator (`vergenced`): a service on the home
/// server or a desktop that hands a title's analysis to worker machines in
/// 2 s pieces and serves the results while they are made, nearest the
/// playhead first (`docs/plans/analysis-workers.md`). Convolution tells it
/// where it is playing and reads 10 s chunks, partial ones included, so a
/// 3D title's Smooth Motion fields arrive while it plays instead of after a
/// night's analysis.
///
/// Set in Settings (the address in defaults, the token in the Keychain); it
/// knows Jellyfin items by their id, as the Library does.
struct AnalysisCoordinator: Sendable {
    let baseURL: URL
    let token: String
    /// This device among the coordinator's players.
    let player: String

    static let urlKey = "analysisCoordinatorURL"
    static let playerKey = "analysisCoordinatorPlayer"
    static let smoothMotion3D = "smooth-motion-3d"

    /// The configured coordinator, or nil when there is none.
    static func current() -> AnalysisCoordinator? {
        guard let text = UserDefaults.standard.string(forKey: urlKey)?.trimmingCharacters(in: .whitespaces),
              !text.isEmpty, let url = URL(string: text), url.scheme == "http" || url.scheme == "https",
              let token = KeychainStore.string(for: .analysisCoordinatorToken), !token.isEmpty else { return nil }
        return AnalysisCoordinator(baseURL: url, token: token, player: playerID())
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

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        return request
    }

    /// Says where this device is playing a Jellyfin item, which queues the
    /// title (described by the coordinator from the server) and puts the
    /// pieces around `seconds` first. Throws for a title it won't work on
    /// (not stereo, a disc, a server it doesn't know).
    @discardableResult
    func playing(itemId: String, seconds: Double, rate: Double = 1) async throws -> Status {
        var request = request("v1/playing", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "server": "jellyfin", "id": itemId, "workload": Self.smoothMotion3D,
            "seconds": max(seconds, 0), "rate": rate, "player": player,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw Failure.http(status) }
        return try JSONDecoder().decode(Status.self, from: data)
    }

    /// This device stopped playing.
    func stopped() async {
        var request = request("v1/playing", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "server": "jellyfin", "id": "", "seconds": 0, "player": player, "stopped": true,
        ])
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Chunk `index` of an item's Smooth Motion track, whole or not.
    func chunk(itemId: String, index: Int) async throws -> StreamingAnalysisChunk {
        let (data, response) = try await URLSession.shared.data(
            for: request("v1/titles/jellyfin/\(itemId)/\(Self.smoothMotion3D)/chunks/\(index)"))
        let http = response as? HTTPURLResponse
        switch http?.statusCode {
        case 200:
            return StreamingAnalysisChunk(data: data, isComplete: http?.value(forHTTPHeaderField: "Vergence-Chunk-Complete") != "false")
        case 404: throw Failure.notReady
        case let status: throw Failure.http(status ?? -1)
        }
    }
}

/// Tells the coordinator where the player is, from the playheads the field
/// lookup hears every frame: every few seconds while playing, at once after
/// a seek, and that it stopped when the track is let go.
final class AnalysisPlayheadReporter: @unchecked Sendable {
    private let coordinator: AnalysisCoordinator
    private let itemId: String
    private let lock = NSLock()
    private var lastSent: (seconds: Double, at: Date)?
    private var sending = false
    /// How often a steady playhead is reported (the coordinator forgets one after 20 s).
    private static let interval: TimeInterval = 5
    /// A playhead this far from where the last report says it should be is a seek.
    private static let seekSeconds = 3.0

    init(coordinator: AnalysisCoordinator, itemId: String, startSeconds: Double) {
        self.coordinator = coordinator
        self.itemId = itemId
        lastSent = (startSeconds, Date())
    }

    deinit {
        let coordinator = coordinator
        Task.detached(priority: .utility) { await coordinator.stopped() }
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
        let coordinator = coordinator, itemId = itemId
        Task.detached(priority: .utility) { [weak self] in
            do {
                try await coordinator.playing(itemId: itemId, seconds: seconds)
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
