/*
 Hypnos - Media Authorization

 Maps a media server's host to the credential that authenticates requests to
 it, so "how do I attach auth to this URL" has one answer instead of a
 `?apikey=` literal hand-copied into every consumer.

 Stash and Nextcloud need genuinely different mechanisms — a query parameter
 the server itself already bakes into most URLs it hands back, versus a Basic
 `Authorization` header that has no query-string equivalent — so the type this
 resolves to is a small enum rather than a single "auth token" string, and
 each consumer asks for the *shape* it can use (a full `URLRequest`, bare
 header fields for `AVURLAsset`, or a query-decorated `URL` for a caller that
 can only hand WebKit a `src` attribute).
 */

import AVFoundation
import Foundation
import os

/// How to authenticate requests to one configured media server.
enum MediaCredential: Equatable, Sendable {
    /// Appended as a query item, e.g. Stash's `?apikey=...` — the server
    /// itself already bakes this into most URLs it returns, so this exists
    /// for the URLs the app derives client-side (transcode variants, preview
    /// clips) that don't come pre-authenticated.
    case queryParam(name: String, value: String)
    /// Sent as a request header, e.g. Nextcloud's Basic auth. Has no query
    /// form, so a consumer that can only carry a bare `URL` (an HTML5
    /// `<video src>`) cannot use this — see `MediaAuthorization.authorizedURL`.
    case header(name: String, value: String)
}

/// Resolves a URL's host to the credential that should authenticate it.
///
/// A process-wide registry rather than something threaded through every
/// loader: `ImageLoader` is a singleton actor with no reference to
/// `AppModel`, and the WebKit-hosted image/video views build their HTML
/// independent of any model. `AppModel` is the sole writer — it registers or
/// unregisters a server's credential whenever it's configured or removed —
/// and everything else only ever reads.
struct MediaAuthorization: Sendable {
    static let shared = MediaAuthorization()

    private struct Entry: Sendable {
        let host: String
        let credential: MediaCredential
    }

    private let state = OSAllocatedUnfairLock(initialState: [Entry]())

    /// URL prefixes that belong to a different server than the one
    /// registered for their host, keyed by who set them. A host's credential
    /// is never applied under one of these.
    private let exclusions = OSAllocatedUnfairLock(initialState: [String: URL]())

    private init() {}

    /// Marks everything under `baseURL` as belonging to another server, so the
    /// credential registered for its host is not applied there; nil clears it.
    ///
    /// Credentials are matched by host alone, which is wrong when two servers
    /// sit behind one reverse proxy: with Stash at `host/stash` and Jellyfin
    /// at `host/jellyfin`, Stash's `?apikey=` went onto every Jellyfin stream
    /// URL, and Jellyfin 10.11 reads it as its own `ApiKey` (query keys are
    /// case-insensitive there), prefers it over `api_key`, and answers 401.
    func excludeCredentials(under baseURL: URL?, owner: String) {
        exclusions.withLock { $0[owner] = baseURL }
    }

    /// Registers (or replaces) the credential for `host`, which is a bare
    /// hostname (`URL.host`), not a URL — accepting both would mean guessing
    /// which one a caller meant, and `URL(string:)` reads a bare `host:port`
    /// as a scheme rather than a host, so the guess would sometimes be wrong
    /// in a way that silently never matches.
    func register(host: String, credential: MediaCredential) {
        guard let normalized = normalizedHost(host) else { return }
        state.withLock { entries in
            entries.removeAll { $0.host == normalized }
            entries.append(Entry(host: normalized, credential: credential))
        }
    }

    func unregister(host: String) {
        guard let normalized = normalizedHost(host) else { return }
        state.withLock { entries in entries.removeAll { $0.host == normalized } }
    }

    func credential(for url: URL) -> MediaCredential? {
        guard let host = normalizedHost(url.host), !isExcluded(url) else { return nil }
        return state.withLock { entries in entries.first { $0.host == host }?.credential }
    }

    // MARK: - Applying a credential

    /// An authenticated `URLRequest` for `url`, whichever form its host's
    /// credential takes.
    ///
    /// It applies the query param as well as the header, even though Stash
    /// bakes its key into most URLs it hands back: `authorizedURL` is a no-op
    /// on a URL that already carries the parameter, so the cost is nothing and
    /// the alternative is a primitive that silently returns an unauthenticated
    /// request for a client-derived Stash URL.
    func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: authorizedURL(url))
        if case .header(let name, let value) = credential(for: url) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    /// Header fields for a consumer that can't build a `URLRequest`. Empty for
    /// a query-param credential or an unregistered host.
    func headerFields(for url: URL) -> [String: String] {
        guard case .header(let name, let value) = credential(for: url) else { return [:] }
        return [name: value]
    }

    /// An authenticated `AVURLAsset`.
    ///
    /// Every AVFoundation path goes through this so the decode probe and the
    /// player that acts on its answer cannot disagree: a probe built without
    /// the header reports a perfectly playable Nextcloud video as undecodable
    /// (a 401 is indistinguishable from an unsupported container from here),
    /// which routes it to WebKit — where a bare `<video src>` can't
    /// authenticate either, so it fails there too.
    func asset(for url: URL) -> AVURLAsset {
        let fields = headerFields(for: url)
        guard !fields.isEmpty else { return AVURLAsset(url: authorizedURL(url)) }
        // The Swift overlay no longer exposes `AVURLAssetHTTPHeaderFieldsKey`
        // as a symbol — verified absent from every SDK's AVFoundation
        // swiftinterface, present only in the linker's export list — so the
        // literal is the documented value and the only way to reach the still
        // functional options key.
        return AVURLAsset(url: authorizedURL(url),
                          options: ["AVURLAssetHTTPHeaderFieldsKey": fields])
    }

    /// `url` with a query-param credential appended. A header credential
    /// (Nextcloud) has no query form and is returned unchanged — a consumer
    /// that needs one authenticated must go through `request(for:)` or
    /// `headerFields(for:)` instead, or (for WebKit `<video>`/`<img>` src,
    /// which can carry neither) fetch the bytes itself and hand WebKit a
    /// blob URL, the way `AnimatedImageWebView`'s header path does.
    func authorizedURL(_ url: URL) -> URL {
        guard case .queryParam(let name, let value) = credential(for: url),
              !value.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var queryItems = components.queryItems ?? []
        guard !queryItems.contains(where: { $0.name == name }) else { return url }
        queryItems.append(URLQueryItem(name: name, value: value))
        components.queryItems = queryItems
        return components.url ?? url
    }

    private func isExcluded(_ url: URL) -> Bool {
        let bases = exclusions.withLock { Array($0.values) }
        return bases.contains { base in
            guard normalizedHost(base.host) == normalizedHost(url.host),
                  effectivePort(base) == effectivePort(url) else { return false }
            let prefix = base.path.hasSuffix("/") ? String(base.path.dropLast()) : base.path
            return prefix.isEmpty || url.path == prefix || url.path.hasPrefix(prefix + "/")
        }
    }

    private func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : url.scheme?.lowercased() == "http" ? 80 : nil)
    }

    private func normalizedHost(_ host: String?) -> String? {
        guard let host, !host.isEmpty else { return nil }
        return host.lowercased()
    }
}
