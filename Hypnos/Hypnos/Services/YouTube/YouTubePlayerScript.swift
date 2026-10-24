/*
 Hypnos - YouTube's player script: its signature timestamp, and solving its
 stream URL challenges (sideload builds only: `HYPNOS_YOUTUBE`)

 The visionOS client's HLS master needs none of this. The TV client
 (`YouTubeSurround`), which is what lists the 5.1 tracks, answers with plain
 stream URLs whose `n` parameter has to be run through a function in the
 player script first, or googlevideo answers 403 (measured 2026-10-25), and
 it only answers at all when told the script's `signatureTimestamp`. A
 format may also come as a `signatureCipher` whose `s` needs the same
 treatment.

 The script (`base.js`, ~3 MB) is fetched from youtube.com once per player
 version (the id in `iframe_api`) and kept in Caches. yt-dlp's EJS solver
 (`YouTubeSolverScript`) finds and runs the two functions in
 JavaScriptCore: ~1.8 s on an M-series Mac for the first challenge of a
 player version; the parsed player is kept in memory, so later ones are
 quick. When YouTube changes the player in a way the solver can't follow,
 solving fails and surround is simply not offered;
 `scripts/update-youtube-solver.sh` brings in a newer solver.
 */

#if HYPNOS_YOUTUBE

import DebugTrace
import Foundation
import JavaScriptCore

enum YouTubePlayerScriptError: LocalizedError {
    case noPlayerID
    case noSignatureTimestamp
    case solverFailed(String)

    var errorDescription: String? {
        switch self {
        case .noPlayerID: "YouTube's player version couldn't be found."
        case .noSignatureTimestamp: "YouTube's player script has no signature timestamp."
        case .solverFailed(let reason): "YouTube's stream challenge couldn't be solved: \(reason)"
        }
    }
}

actor YouTubePlayerScript {
    static let shared = YouTubePlayerScript()

    struct Player: Sendable {
        let id: String
        let source: String
        let signatureTimestamp: Int
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    private var current: (player: Player, checked: Date)?
    /// The solver's parsed form of `current`, which later solves start from.
    private var preprocessed: (id: String, code: String)?

    private static let agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15"

    private static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YouTubePlayer", isDirectory: true)
    }

    /// The player version YouTube serves now (checked hourly), its script
    /// from the cache or youtube.com.
    func player() async throws -> Player {
        if let current, Date().timeIntervalSince(current.checked) < 3600 { return current.player }
        try YouTubeConsent.require()
        let api = try await text(at: URL(string: "https://www.youtube.com/iframe_api")!)
        guard let match = api.firstMatch(of: #/player\\?\/([0-9a-fA-F]{8})\\?\//#) else {
            throw YouTubePlayerScriptError.noPlayerID
        }
        let id = String(match.1)
        if let current, current.player.id == id {
            self.current = (current.player, Date())
            return current.player
        }
        let file = Self.cacheDirectory.appendingPathComponent("\(id).js")
        let source: String
        if let cached = try? String(contentsOf: file, encoding: .utf8) {
            source = cached
        } else {
            source = try await text(at: URL(string: "https://www.youtube.com/s/player/\(id)/player_ias.vflset/en_US/base.js")!)
            try? FileManager.default.removeItem(at: Self.cacheDirectory)
            try? FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
            try? source.write(to: file, atomically: true, encoding: .utf8)
        }
        guard let stamp = source.firstMatch(of: #/(?:signatureTimestamp|sts)\s*:\s*(\d{5})/#),
              let timestamp = Int(stamp.1) else {
            throw YouTubePlayerScriptError.noSignatureTimestamp
        }
        let player = Player(id: id, source: source, signatureTimestamp: timestamp)
        current = (player, Date())
        AppLogger.youtube.info("Player script \(id, privacy: .public): \(source.utf8.count / 1024, privacy: .public) KB, signature timestamp \(timestamp, privacy: .public)")
        return player
    }

    /// Each challenge's answer, for `n` challenges and signature (`sig`) ones.
    func solve(n: [String], signatures: [String] = [], for player: Player) throws -> (n: [String: String], signatures: [String: String]) {
        var requests: [[String: Any]] = []
        if !n.isEmpty { requests.append(["type": "n", "challenges": n]) }
        if !signatures.isEmpty { requests.append(["type": "sig", "challenges": signatures]) }
        guard !requests.isEmpty else { return ([:], [:]) }

        let start = Date()
        let context = JSContext()!
        var thrown: String?
        context.exceptionHandler = { _, exception in thrown = exception?.toString() }
        context.evaluateScript(YouTubeSolverScript.lib)
        context.evaluateScript("Object.assign(globalThis, lib);")
        context.evaluateScript(YouTubeSolverScript.core)
        if let thrown { throw YouTubePlayerScriptError.solverFailed("loading the solver: \(thrown)") }

        var input: [String: Any] = ["requests": requests]
        if let preprocessed, preprocessed.id == player.id {
            input["type"] = "preprocessed"
            input["preprocessed_player"] = preprocessed.code
        } else {
            input["type"] = "player"
            input["player"] = player.source
            input["output_preprocessed"] = true
        }
        let output = context.objectForKeyedSubscript("jsc").call(withArguments: [input])
        if let thrown { throw YouTubePlayerScriptError.solverFailed(thrown) }
        guard let result = output?.toDictionary(), result["type"] as? String == "result",
              let responses = result["responses"] as? [[String: Any]] else {
            throw YouTubePlayerScriptError.solverFailed("no result")
        }
        if let code = result["preprocessed_player"] as? String { preprocessed = (player.id, code) }

        var answers: (n: [String: String], signatures: [String: String]) = ([:], [:])
        for (request, response) in zip(requests, responses) {
            guard response["type"] as? String == "result", let data = response["data"] as? [String: String] else {
                throw YouTubePlayerScriptError.solverFailed(response["error"] as? String ?? "\(request["type"] ?? "?") failed")
            }
            if request["type"] as? String == "n" { answers.n = data } else { answers.signatures = data }
        }
        AppLogger.youtube.info("Solved \(n.count + signatures.count, privacy: .public) stream challenge(s) in \(Date().timeIntervalSince(start), format: .fixed(precision: 2), privacy: .public) s")
        return answers
    }

    private func text(at url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue(Self.agent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw YouTubeInnertubeError.badResponse(http.statusCode)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

#endif
