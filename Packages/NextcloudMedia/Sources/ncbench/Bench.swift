import Foundation
import NextcloudMedia

// Live bench for the Nextcloud client. Hits a real server so the offline tests
// can stay offline.
//
//   export NC_SERVER=https://cloud.example.com
//   export NC_USER=someone
//   export NC_APP_PASSWORD=...        # an app password, never the account one
//   export NC_ROOT=Photos             # optional, defaults to Photos
//
//   swift run ncbench login https://cloud.example.com   # get an app password
//   swift run ncbench verify
//   swift run ncbench search --kind images --limit 20
//   swift run ncbench page --limit 100 --pages 5        # paging cost at depth
//
// The app password is never printed: `login` writes it to a 0600 file and says
// only where it went. Printing it would put a live credential in a terminal
// transcript.
//
// Written as a `@main` struct rather than top-level code because Swift 6 makes
// top-level bindings main-actor isolated while sibling helpers are not, so
// every helper that reads an argument fails to compile.
@main
struct Bench {

    static func main() async {
        // Line-buffer stdout. Swift's `print` block-buffers whenever stdout is
        // not a terminal, so `login` — whose entire job is to show a URL and
        // then wait for the user — emits nothing at all when piped or
        // redirected, and looks like it hung before it ever got going.
        setvbuf(stdout, nil, _IOLBF, 0)
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    // MARK: - Arguments

    static let allArguments = Array(CommandLine.arguments.dropFirst())
    static var command: String { allArguments.first ?? "help" }
    static var flags: [String] { Array(allArguments.dropFirst()) }

    static func flag(_ name: String) -> String? {
        let flags = self.flags
        guard let index = flags.firstIndex(of: "--\(name)") else { return nil }
        let next = flags.index(after: index)
        guard next < flags.endIndex else { return nil }
        return flags[next]
    }

    static func intFlag(_ name: String, default fallback: Int) -> Int {
        flag(name).flatMap(Int.init) ?? fallback
    }

    static func environment(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key].flatMap { $0.isEmpty ? nil : $0 }
    }

    struct BenchError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func makeServer() throws -> NextcloudServer {
        guard let raw = environment("NC_SERVER"),
              let base = NextcloudLoginFlow.normalizeServerURL(raw) else {
            throw BenchError(message: "set NC_SERVER (and NC_USER, NC_APP_PASSWORD)")
        }
        guard let user = environment("NC_USER") else {
            throw BenchError(message: "set NC_USER")
        }
        guard let password = environment("NC_APP_PASSWORD") else {
            throw BenchError(message: "set NC_APP_PASSWORD")
        }
        return NextcloudServer(baseURL: base, username: user, appPassword: password,
                               root: environment("NC_ROOT") ?? "Photos")
    }

    static func parseKind(_ raw: String?) -> NextcloudQuery.Kind {
        switch raw?.lowercased() {
        case "videos", "video": return .videos
        case "both", "all": return .both
        default: return .images
        }
    }

    /// Wall-clock milliseconds for one async call.
    static func timed<T>(_ body: () async throws -> T) async rethrows -> (T, Double) {
        let clock = ContinuousClock()
        var value: T!
        let elapsed = try await clock.measure { value = try await body() }
        let ms = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        return (value, ms)
    }

    // MARK: - Commands

    static func run() async throws {
        switch command {
        case "login":   try await login()
        case "verify":  try await verify()
        case "search":  try await search()
        case "page":    try await page()
        case "preview": try await preview()
        case "folders": try await folders()
        default:        usage()
        }
    }

    static func login() async throws {
        guard let host = flags.first(where: { !$0.hasPrefix("--") }) ?? environment("NC_SERVER") else {
            throw BenchError(message: "usage: ncbench login <server-url>")
        }
        let flow = NextcloudLoginFlow(userAgent: "Convolution (ncbench)")
        let session = try await flow.begin(serverURL: host)
        print("Open this and approve:\n\n  \(session.loginURL.absoluteString)\n")
        print("Waiting…")
        let credentials = try await flow.awaitApproval(session)

        let destination = URL(fileURLWithPath: ".ncbench-credentials.json")
        let payload = [
            "server": credentials.server,
            "loginName": credentials.loginName,
            "appPassword": credentials.appPassword,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload,
                                              options: .prettyPrinted)
        try data.write(to: destination, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: destination.path)
        print("""
            OK  server=\(credentials.server)  user=\(credentials.loginName)
            App password written to \(destination.path) (0600). Export it with:
              export NC_APP_PASSWORD=$(python3 -c 'import json;print(json.load(open(".ncbench-credentials.json"))["appPassword"])')
            """)
    }

    static func verify() async throws {
        let client = NextcloudClient(server: try makeServer())
        let (count, ms) = try await timed { try await client.verify() }
        print(count > 0
            ? String(format: "OK — credentials work and the root has media (%.0f ms)", ms)
            : "Reachable, but the configured root returned nothing. Check NC_ROOT.")
    }

    static func search() async throws {
        let client = NextcloudClient(server: try makeServer())
        let query = NextcloudQuery(kind: parseKind(flag("kind")),
                                   offset: intFlag("offset", default: 0),
                                   limit: intFlag("limit", default: 20),
                                   searchTerm: flag("term") ?? "")
        let (page, ms) = try await timed { try await client.search(query) }

        print(String(format: "%d items in %.0f ms (hasMore: %@)",
                     page.items.count, ms, page.hasMore ? "yes" : "no"))
        for item in page.items {
            let dimensions = item.pixelSize.map { "\($0.width)x\($0.height)" } ?? "-"
            let name = String(item.filename.prefix(42)).padding(toLength: 42,
                                                                withPad: " ",
                                                                startingAt: 0)
            let type = item.contentType.padding(toLength: 16, withPad: " ", startingAt: 0)
            print("  \(name) \(type) id=\(item.fileID)  "
                + "prev=\(item.hasPreview ? "yes" : "NO ")  "
                + "size=\(dimensions)  blur=\(item.blurHash == nil ? "-" : "yes")")
        }
    }

    static func page() async throws {
        // The claim worth re-checking on any server: offset is resolved in SQL,
        // so page 50 should cost about what page 1 does.
        let client = NextcloudClient(server: try makeServer())
        let limit = intFlag("limit", default: 100)
        let pages = intFlag("pages", default: 5)
        let kind = parseKind(flag("kind"))
        print("limit=\(limit), \(pages) pages")
        for index in 0..<pages {
            let query = NextcloudQuery(kind: kind, offset: index * limit, limit: limit)
            let (result, ms) = try await timed { try await client.search(query) }
            print(String(format: "  offset %-7d %4d items  %6.0f ms",
                         index * limit, result.items.count, ms))
        }
    }

    static func preview() async throws {
        guard let fileID = flag("id").flatMap(Int.init) else {
            throw BenchError(message: "usage: ncbench preview --id <fileId> [--size 512]")
        }
        let client = NextcloudClient(server: try makeServer())
        let size = intFlag("size", default: 512)
        guard let request = await client.previewRequest(fileID: fileID, size: size) else {
            throw BenchError(message: "could not build a preview URL")
        }
        let (result, ms) = try await timed {
            try await URLSession.shared.data(for: request)
        }
        if let http = result.1 as? HTTPURLResponse, http.statusCode != 200 {
            throw BenchError(message: "HTTP \(http.statusCode)")
        }
        print(String(format: "preview %d @ %dpx: %d KiB in %.0f ms",
                     fileID, size, result.0.count / 1024, ms))
    }

    static func folders() async throws {
        let client = NextcloudClient(server: try makeServer())
        let path = flag("path") ?? ""
        let (list, ms) = try await timed { try await client.folders(in: path) }
        print(String(format: "%d folders under %@ in %.0f ms",
                     list.count, path.isEmpty ? "/" : path, ms))
        for folder in list {
            let size = folder.totalBytes.map { " (\($0) bytes)" } ?? ""
            print("  \(folder.path)\(size)")
        }
    }

    static func usage() {
        print("""
            ncbench — live bench for the Nextcloud client

              login <server-url>                     run Login Flow v2, save an app password
              verify                                 check credentials and root
              search [--kind images|videos|both] [--limit N] [--offset N] [--term T]
              page   [--limit N] [--pages N]         paging cost at increasing depth
              preview --id <fileId> [--size 512]
              folders [--path Photos]                list collections, for the root picker

            Environment: NC_SERVER, NC_USER, NC_APP_PASSWORD, NC_ROOT (default Photos)
            """)
    }
}
