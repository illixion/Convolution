/*
 Hypnos - Library feature: getting a server intro markers

 Skip Intro and Skip Credits play off markers the server reports
 (`MediaSegmentSkipper`), and stock Jellyfin makes none. A segment provider
 plugin has to. Without one, only files whose own chapters are named
 "Intro" or "Credits" get a skip button, which is why one show from a
 server skips and another from the same server doesn't (found 2026-10-20:
 Archer's files carry "Intro"/"Credits" chapters, House M.D.'s only
 "Chapter 1"…"Chapter 6").

 This checks the server for Intro Skipper, which finds intros and credits by
 comparing the audio of a season's episodes, and for an administrator
 installs it through the server's own plugin API:
 add its repository, install, restart, then (optionally) analyse now rather
 than at the plugin's nightly run. Measured end to end on the dev instance.

 The app only ever talks to the user's own server. Installing makes the
 *server* fetch the plugin from the Intro Skipper repository and GitHub,
 so it only happens from a button whose confirmation says so; the one
 request made unasked is reading the server's plugin list.
 */

import DebugTrace
import Foundation
import Observation
import RAVEUI

@MainActor
@Observable
final class IntroSkipperSetup {
    static let shared = IntroSkipperSetup()

    /// The server to talk to: the configured one, or (the macOS harness)
    /// the dev instance.
    @ObservationIgnored private let server: @MainActor () -> JellyfinHTTP?

    init(server: @escaping @MainActor () -> JellyfinHTTP? = { LibraryService.current()?.http }) {
        self.server = server
    }

    enum Status: Equatable {
        /// Not checked yet, or the server didn't answer.
        case unknown
        /// The account can't read the plugin list (not an administrator).
        case notAdmin
        case missing
        /// Installed; Jellyfin loads it at its next restart.
        case needsRestart
        case active
        /// Installed but not running, with Jellyfin's word for why
        /// ("Disabled", "NotSupported", "Malfunctioned").
        case inactive(String)
    }

    enum Work: Equatable { case installing, restarting, startingAnalysis }

    /// The plugin's own "Detect and Analyze Media Segments" task.
    struct Analysis: Equatable {
        var isRunning: Bool
        var progress: Double?
        var lastRun: Date?
    }

    private(set) var status: Status = .unknown
    private(set) var isChecking = false
    private(set) var work: Work?
    private(set) var analysis: Analysis?
    private(set) var error: String?

    @ObservationIgnored private var checkedKey: String?
    @ObservationIgnored private var checkedAt: Date?

    static let pluginId = "c83d86bba1e04c35a113e2101cf4ee6b"
    static let pluginName = "Intro Skipper"
    /// Answers with the manifest for the asking server's Jellyfin version.
    static let repositoryURL = "https://intro-skipper.org/manifest.json"
    static let analysisTaskKey = "IntroSkipperDetectSegmentsTask"
    static let hintDismissedKey = "library.skipMarkersHintDismissed"

    /// Whether to point the user at installing it.
    var suggestsInstall: Bool { status == .missing || status == .notAdmin }

    // MARK: Checking

    /// Reads the plugin list, at most every ten minutes per server unless
    /// `force`d.
    func refresh(force: Bool = false) async {
        let key = LibraryService.configurationKey
        if !force, key == checkedKey, let checkedAt, Date().timeIntervalSince(checkedAt) < 600 { return }
        guard let http = server() else {
            status = .unknown
            return
        }
        isChecking = true
        defer { isChecking = false }
        do {
            let plugins = try JSONDecoder().decode([JFPlugin].self, from: await http.data("Plugins", timeout: 10))
            status = Self.status(of: plugins)
            analysis = status == .active ? await analysisState(http) : nil
        } catch JellyfinHTTP.Failure.http(let code) where code == 401 || code == 403 {
            status = .notAdmin
        } catch {
            status = .unknown
            return
        }
        checkedKey = key
        checkedAt = Date()
    }

    func refreshAnalysis() async {
        guard status == .active, let http = server() else { return }
        analysis = await analysisState(http)
    }

    /// Whether a series' detail page should mention the plugin: the server
    /// has no provider and the episode Play starts has no markers either
    /// (no named chapters). Stays quiet once the user said so.
    func suggestsInstall(for episode: LibraryItem?) async -> Bool {
        guard let episode, !UserDefaults.standard.bool(forKey: Self.hintDismissedKey),
              let library = LibraryService.current() else { return false }
        await refresh()
        guard suggestsInstall else { return false }
        let segments = (try? await library.mediaSegments(itemId: episode.id)) ?? []
        return !segments.contains(where: LibrarySegmentSkipPolicy.eligible)
    }

    private static func status(of plugins: [JFPlugin]) -> Status {
        guard let plugin = plugins.first(where: {
            $0.Id?.replacingOccurrences(of: "-", with: "").lowercased() == pluginId || $0.Name == pluginName
        }) else { return .missing }
        switch plugin.Status {
        case "Active", nil: return .active
        case "Restart": return .needsRestart
        case let other?: return .inactive(other)
        }
    }

    // MARK: Server actions (each from a confirmed button)

    /// Adds the plugin's repository to the server (once) and installs the
    /// build the repository offers for the server's Jellyfin version.
    func install() async {
        guard work == nil, let http = server() else { return }
        work = .installing
        error = nil
        defer { work = nil }
        do {
            // Round-tripped as plain JSON so fields this app doesn't know survive.
            var repositories = try JSONSerialization.jsonObject(with: await http.data("Repositories")) as? [[String: Any]] ?? []
            if !repositories.contains(where: { ($0["Url"] as? String) == Self.repositoryURL }) {
                repositories.append(["Name": Self.pluginName, "Url": Self.repositoryURL, "Enabled": true])
                _ = try await http.data("Repositories", method: "POST",
                                        body: JSONSerialization.data(withJSONObject: repositories))
            }
            // The server fetches every repository's manifest to answer this.
            let packages = try JSONDecoder().decode([JFPackage].self, from: await http.data("Packages", timeout: 60))
            guard let package = packages.first(where: { $0.guid?.replacingOccurrences(of: "-", with: "").lowercased() == Self.pluginId }),
                  !(package.versions ?? []).isEmpty
            else {
                error = "Intro Skipper has no build for this server's version of Jellyfin yet."
                return
            }
            _ = try await http.data("Packages/Installed/\(Self.pluginName)", query: [
                URLQueryItem(name: "assemblyGuid", value: Self.pluginId),
                URLQueryItem(name: "repositoryUrl", value: Self.repositoryURL),
            ], method: "POST", timeout: 60)
            AppLogger.library.info("Intro Skipper install requested on the server")
            // The install runs on the server after the request returns.
            for _ in 0..<30 {
                await refresh(force: true)
                if status != .missing && status != .unknown { return }
                try await Task.sleep(for: .seconds(2))
            }
            error = "The server took the request but hasn't finished installing. Check Dashboard → Plugins on the server."
        } catch {
            AppLogger.library.error("Intro Skipper install failed: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            self.error = "Couldn't install Intro Skipper: \(error.localizedDescription)"
        }
    }

    /// Restarts Jellyfin so it loads the plugin, and waits for it to answer
    /// again (about half a minute on the dev instance).
    func restartServer() async {
        guard work == nil, let http = server() else { return }
        work = .restarting
        error = nil
        defer { work = nil }
        do {
            _ = try await http.data("System/Restart", method: "POST")
        } catch {
            self.error = "Couldn't restart the server: \(error.localizedDescription)"
            return
        }
        // It keeps answering for a moment before it goes down.
        try? await Task.sleep(for: .seconds(4))
        for _ in 0..<60 {
            if (try? await http.data("System/Info/Public", timeout: 3)) != nil { break }
            try? await Task.sleep(for: .seconds(3))
        }
        await refresh(force: true)
        if status == .needsRestart {
            error = "The server is back but hasn't loaded Intro Skipper. Check Dashboard → Plugins on the server."
        }
    }

    /// Runs the analysis now instead of at its nightly time.
    func startAnalysis() async {
        guard work == nil, let http = server() else { return }
        work = .startingAnalysis
        error = nil
        defer { work = nil }
        do {
            guard let task = try await analysisTask(http), let id = task.Id else {
                error = "The server doesn't list Intro Skipper's analysis task. Restart it, then try again."
                return
            }
            _ = try await http.data("ScheduledTasks/Running/\(id)", method: "POST")
            analysis = Analysis(isRunning: true, progress: nil, lastRun: analysis?.lastRun)
        } catch {
            self.error = "Couldn't start the analysis: \(error.localizedDescription)"
        }
    }

    private func analysisState(_ http: JellyfinHTTP) async -> Analysis? {
        guard let task = try? await analysisTask(http) else { return nil }
        return Analysis(isRunning: task.State == "Running",
                        progress: task.CurrentProgressPercentage.map { $0 / 100 },
                        lastRun: task.LastExecutionResult?.EndTimeUtc.flatMap(JellyfinDate.parse))
    }

    private func analysisTask(_ http: JellyfinHTTP) async throws -> JFScheduledTask? {
        let tasks = try JSONDecoder().decode([JFScheduledTask].self, from: await http.data("ScheduledTasks"))
        return tasks.first { $0.Key == Self.analysisTaskKey }
    }
}

private struct JFPlugin: Decodable {
    let Name: String?
    let Id: String?
    let Status: String?
}

private struct JFPackage: Decodable {
    struct Version: Decodable { let version: String? }
    let guid: String?
    let versions: [Version]?
}

private struct JFScheduledTask: Decodable {
    struct Result: Decodable { let EndTimeUtc: String? }
    let Id: String?
    let Key: String?
    let State: String?
    let CurrentProgressPercentage: Double?
    let LastExecutionResult: Result?
}
