/*
 Hypnos - Library feature: the current MediaServerLibrary, if any

 One place that turns "is Jellyfin configured, and how" into a
 `MediaServerLibrary` the Library tab can call — every platform's Library
 root view goes through this rather than each reaching into
 `FilmSession`/`JellyfinAuth` separately.
 */

import Foundation

@MainActor
enum LibraryService {
    /// The active library, or nil when no server is configured or the
    /// address doesn't parse. Built fresh each time rather than cached: a
    /// `JellyfinLibrary` is a cheap actor wrapper around a URL and a token,
    /// and rebuilding picks up a server/sign-in change immediately with no
    /// invalidation logic to get wrong.
    static func current() -> JellyfinLibrary? {
        let session = FilmSession.shared
        let trimmed = session.server.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed),
              url.scheme != nil
        else { return nil }

        if let authSession = JellyfinAuth.shared.session {
            return JellyfinLibrary(baseURL: url, accessToken: authSession.accessToken, userId: authSession.userId)
        }
        guard !session.apiKey.isEmpty else { return nil }
        return JellyfinLibrary(baseURL: url, accessToken: session.apiKey, userId: nil)
    }
}
