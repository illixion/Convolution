/*
 Hypnos - Library feature: Jellyfin sign-in

 Progress reporting (`/Sessions/Playing*`, mark played/unplayed, favorite)
 needs a user context, not just an API key. This adds real Jellyfin
 username/password sign-in (`/Users/AuthenticateByName`) alongside the
 existing plain-API-key mode `FilmSession` already has: sign in once, keep
 the resulting access token + user id in the Keychain, and reuse them across
 launches like any other Jellyfin client.

 API-key mode still works as a fallback for anyone who'd rather paste a key
 than sign in — `JellyfinLibrary` picks a user to report progress as via
 `/Users` in that case (see its `resolveUserId`).
 */

import Foundation
import Observation
import os

/// The `Authorization` header every Jellyfin request needs, built once and
/// reused by both `JellyfinAuth` and `JellyfinLibrary` so the client
/// identity string can't drift between them.
enum JellyfinClientIdentity {
    static let clientName = "Hypnos"
    static let deviceName = platformDeviceName
    /// Stable per-install id; a Jellyfin server uses this to distinguish
    /// "sessions" for the same user across devices.
    static let deviceId: String = {
        let key = "jellyfin.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()
    static let version = "1.0"

    /// The base `Authorization` header value, with an optional `Token=`
    /// suffix once a session/access token exists. Jellyfin accepts this
    /// same header shape for both the unauthenticated `AuthenticateByName`
    /// call (no token) and every authenticated call (with one).
    static func authorizationHeader(token: String? = nil) -> String {
        var value = "MediaBrowser Client=\"\(clientName)\", Device=\"\(deviceName)\", DeviceId=\"\(deviceId)\", Version=\"\(version)\""
        if let token, !token.isEmpty {
            value += ", Token=\"\(token)\""
        }
        return value
    }

    private static var platformDeviceName: String {
        #if os(visionOS)
        return "Apple Vision Pro"
        #elseif os(tvOS)
        return "Apple TV"
        #elseif os(macOS)
        return "Mac"
        #else
        return "iPhone or iPad"
        #endif
    }
}

enum JellyfinAuthError: Error, LocalizedError {
    case invalidServerURL
    case http(status: Int)
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: return "Enter a valid Jellyfin server URL first."
        case .http(let status): return "Sign-in failed (HTTP \(status))."
        case .decodeFailed: return "Unexpected response from the server."
        }
    }
}

/// One signed-in Jellyfin identity: enough to build the auth header for
/// every later request and to know whose watch state we're syncing.
struct JellyfinSession: Sendable, Equatable {
    var userId: String
    var userName: String
    var accessToken: String
}

/// Username/password sign-in against `/Users/AuthenticateByName`. Reads and
/// writes `JellyfinSession` through `KeychainStore`/`UserDefaults`, the same
/// split every other credential in the app uses (address in defaults,
/// secret in the Keychain).
@MainActor
@Observable
final class JellyfinAuth {
    static let shared = JellyfinAuth()

    private(set) var session: JellyfinSession?
    private(set) var isAuthenticating = false
    private(set) var error: String?

    private init() {
        let userId = UserDefaults.standard.string(forKey: "jellyfin.userId")
        let userName = UserDefaults.standard.string(forKey: "jellyfin.userName")
        let token = KeychainStore.string(for: .jellyfinAccessToken)
        if let userId, let userName, let token {
            session = JellyfinSession(userId: userId, userName: userName, accessToken: token)
        }
    }

    func signIn(serverURL: URL, username: String, password: String) async {
        isAuthenticating = true
        error = nil
        defer { isAuthenticating = false }
        do {
            session = try await Self.authenticate(serverURL: serverURL, username: username, password: password)
            persist(session)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func signOut() {
        session = nil
        persist(nil)
    }

    private func persist(_ session: JellyfinSession?) {
        UserDefaults.standard.set(session?.userId, forKey: "jellyfin.userId")
        UserDefaults.standard.set(session?.userName, forKey: "jellyfin.userName")
        KeychainStore.set(session?.accessToken, for: .jellyfinAccessToken)
    }

    nonisolated static func authenticate(serverURL: URL, username: String, password: String) async throws -> JellyfinSession {
        struct RequestBody: Encodable { let Username: String; let Pw: String }
        struct ResponseBody: Decodable {
            struct UserInfo: Decodable { let Id: String; let Name: String }
            let User: UserInfo
            let AccessToken: String
        }

        var request = URLRequest(url: serverURL.appending(path: "Users/AuthenticateByName"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(JellyfinClientIdentity.authorizationHeader(), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(RequestBody(Username: username, Pw: password))

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw JellyfinAuthError.http(status: status) }
        guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
            throw JellyfinAuthError.decodeFailed
        }
        AppLogger.app.info("Jellyfin sign-in succeeded for user \(decoded.User.Name, privacy: .public)")
        return JellyfinSession(userId: decoded.User.Id, userName: decoded.User.Name, accessToken: decoded.AccessToken)
    }
}
