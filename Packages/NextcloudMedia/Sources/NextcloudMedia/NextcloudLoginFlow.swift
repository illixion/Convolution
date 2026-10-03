import Foundation

/// Nextcloud's Login Flow v2.
///
/// The supported way for a third-party client to get credentials: the app never
/// sees the account password, the user approves in the server's own web login
/// (so 2FA and SSO work unchanged), and what comes back is a revocable
/// **app password** listed per-device under Settings → Security.
///
/// Three steps: `begin()` gets a URL and a poll token, the user opens the URL
/// and approves, `poll()` then returns the credential. The token is single-use
/// and the server expires it after about 20 minutes.
public struct NextcloudLoginFlow: Sendable {

    public struct Session: Sendable, Equatable {
        /// Open this in a browser or web view for the user to approve.
        public let loginURL: URL
        /// Where to poll. Absolute, and *not* necessarily on the same host the
        /// flow started from — the server decides, so don't reconstruct it.
        public let pollEndpoint: URL
        public let token: String
    }

    public struct Credentials: Sendable, Equatable {
        /// The server as it wants to be addressed. May differ from what the
        /// user typed (scheme added, trailing slash dropped, `overwritehost`
        /// applied), and this spelling is the one to persist.
        public let server: String
        public let loginName: String
        public let appPassword: String
    }

    public enum FlowError: Error, LocalizedError, Equatable {
        case invalidServerURL(String)
        case notApprovedYet
        case expiredOrDenied
        case transport(String)
        case malformedResponse

        public var errorDescription: String? {
            switch self {
            case .invalidServerURL(let value): return "Not a valid server URL: \(value)"
            case .notApprovedYet: return "Waiting for approval in the browser."
            case .expiredOrDenied: return "The login request expired or was denied."
            case .transport(let message): return "Network error: \(message)"
            case .malformedResponse: return "The server's login response could not be read."
            }
        }
    }

    private let session: URLSession
    /// Sent as `User-Agent`, and it matters: Nextcloud uses it to name the
    /// app password in Settings → Security, so this is what the user sees when
    /// deciding what to revoke.
    private let userAgent: String

    public init(session: URLSession = .shared, userAgent: String = "Convolution") {
        self.session = session
        self.userAgent = userAgent
    }

    /// Normalizes what a user typed into a base URL.
    ///
    /// Bare hosts get `https://`. A pasted deep link (`/index.php/apps/files`,
    /// or the whole login URL) is trimmed back to the origin, because that is
    /// overwhelmingly what gets pasted out of a browser bar.
    public static func normalizeServerURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://\(text)" }
        guard var components = URLComponents(string: text),
              let host = components.host, !host.isEmpty else { return nil }
        components.query = nil
        components.fragment = nil

        // Keep a subdirectory install's prefix, drop anything that is clearly
        // in-app routing.
        var path = components.path
        for marker in ["/index.php", "/login/v2", "/apps/", "/settings/"] {
            if let range = path.range(of: marker) {
                path = String(path[path.startIndex..<range.lowerBound])
                break
            }
        }
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        return components.url
    }

    /// Step 1: ask the server to start a flow.
    public func begin(serverURL raw: String) async throws -> Session {
        guard let base = Self.normalizeServerURL(raw) else {
            throw FlowError.invalidServerURL(raw)
        }
        var request = URLRequest(url: base.appendingPathComponent("index.php/login/v2"))
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let data = try await send(request)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let loginText = root["login"] as? String,
              let loginURL = URL(string: loginText),
              let poll = root["poll"] as? [String: Any],
              let token = poll["token"] as? String,
              let endpointText = poll["endpoint"] as? String,
              let endpoint = URL(string: endpointText)
        else { throw FlowError.malformedResponse }

        return Session(loginURL: loginURL, pollEndpoint: endpoint, token: token)
    }

    /// Step 2: poll once.
    ///
    /// Throws `.notApprovedYet` while the user has not finished — the server
    /// signals that with **404**, which is a normal state here and not an error
    /// to surface. Callers loop on it.
    public func poll(_ session: Session) async throws -> Credentials {
        var request = URLRequest(url: session.pollEndpoint)
        request.httpMethod = "POST"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded",
                         forHTTPHeaderField: "Content-Type")
        var encoded = CharacterSet.alphanumerics
        encoded.insert(charactersIn: "-._~")
        let escaped = session.token.addingPercentEncoding(withAllowedCharacters: encoded) ?? session.token
        request.httpBody = Data("token=\(escaped)".utf8)

        let data = try await send(request)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let server = root["server"] as? String,
              let loginName = root["loginName"] as? String,
              let appPassword = root["appPassword"] as? String
        else { throw FlowError.malformedResponse }

        return Credentials(server: server, loginName: loginName, appPassword: appPassword)
    }

    /// Polls until approved, cancelled, or `timeout` elapses.
    ///
    /// The interval is the server's own recommendation for this flow; polling
    /// faster earns rate limiting rather than a quicker answer.
    public func awaitApproval(_ session: Session,
                              interval: Duration = .seconds(2),
                              timeout: Duration = .seconds(300)) async throws -> Credentials {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            do {
                return try await poll(session)
            } catch FlowError.notApprovedYet {
                guard ContinuousClock.now < deadline else { throw FlowError.expiredOrDenied }
                try await Task.sleep(for: interval)
            }
        }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FlowError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw FlowError.malformedResponse
        }
        switch http.statusCode {
        case 200..<300: return data
        case 404: throw FlowError.notApprovedYet
        case 403, 410: throw FlowError.expiredOrDenied
        default:
            throw FlowError.transport("HTTP \(http.statusCode)")
        }
    }
}
