/*
 Hypnos - signing in to YouTube (sideload builds only: `HYPNOS_YOUTUBE`)

 The account lives in a web engine's cookies, the way it does in Safari, and
 nowhere else: no cookie is copied out, stored or sent by the app's own
 requests. On visionOS, iOS and macOS that is a WebKit data store of its own
 (the app's other web views never see it); on tvOS, which has no public
 WebKit, it is the shared cookie storage the private `UIWebView` uses. The
 mobile site's own scripts keep the cookies fresh, so the session lasts like
 a phone's would.

 Each device signs in for itself. One session copied to two places, each
 page refreshing its cookies on its own side, can sign the other out.

 Playback never uses any of this: `YouTubeInnertube.player` asks as YouTube's
 visionOS app, signed out, from its own ephemeral session.
 */

#if HYPNOS_YOUTUBE

import DebugTrace
import Foundation
import Observation
#if canImport(WebKit)
import WebKit
#endif

@MainActor
@Observable
final class YouTubeAccount {
    static let shared = YouTubeAccount()

    /// nil until the cookies have been looked at once.
    private(set) var isSignedIn: Bool?

    private init() {}

    /// Safari on an iPhone, as Safari 26 reports itself (the OS version in
    /// it is frozen at 18_6). The mobile site is only served to a phone.
    nonisolated static let userAgent: String = {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/\(os.majorVersion).\(os.minorVersion) Mobile/15E148 Safari/604.1"
    }()

    /// YouTube's own "Sign in" link, landing back on the mobile site.
    nonisolated static let signInURL = URL(string:
        "https://accounts.google.com/ServiceLogin?service=youtube&uilel=3&passive=true"
            + "&continue=https%3A%2F%2Fm.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Dm"
            + "%26next%3Dhttps%253A%252F%252Fm.youtube.com%252F")!

    nonisolated static let homeURL = URL(string: "https://m.youtube.com/")!

    /// Whether a page is the mobile or desktop site itself (not the sign-in
    /// pages, and not `consent.youtube.com`).
    nonisolated static func isYouTubePage(_ url: URL?) -> Bool {
        url?.host == "m.youtube.com" || url?.host == "www.youtube.com"
    }

    #if canImport(WebKit)
    /// Fixed, so the same store is found on every launch.
    static let dataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: "6B1C7E52-3F0A-4D7E-9A51-0C9E2D4B8F31")!)
    #endif

    /// Looks at the cookies again. The `SAPISID` cookies are set on
    /// `.youtube.com` once YouTube has taken the Google sign-in.
    @discardableResult
    func refresh() async -> Bool {
        let signedIn = await Self.cookies().contains { cookie in
            cookie.domain.hasSuffix("youtube.com")
                && (cookie.name == "SAPISID" || cookie.name == "__Secure-3PAPISID")
                && (cookie.expiresDate.map { $0 > Date() } ?? true)
        }
        if isSignedIn != signedIn {
            AppLogger.youtube.info("YouTube account: \(signedIn ? "signed in" : "signed out", privacy: .public)")
        }
        isSignedIn = signedIn
        return signedIn
    }

    /// The page itself said it isn't signed in (the session ended on
    /// Google's side, say), whatever the cookies suggest.
    func pageReportedSignedOut() {
        guard isSignedIn != false else { return }
        AppLogger.youtube.info("YouTube page reports it is signed out")
        isSignedIn = false
    }

    /// Forgets the session on this device. Google still lists it under the
    /// account's devices until it is removed there.
    func signOut() async {
        #if canImport(WebKit)
        await Self.dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        #else
        let storage = HTTPCookieStorage.shared
        for cookie in storage.cookies ?? [] where Self.isAccountDomain(cookie.domain) {
            storage.deleteCookie(cookie)
        }
        #endif
        isSignedIn = false
        AppLogger.youtube.info("YouTube account: signed out on this device")
    }

    private static func isAccountDomain(_ domain: String) -> Bool {
        domain.hasSuffix("youtube.com") || domain.hasSuffix("google.com") || domain.contains(".google.")
    }

    private static func cookies() async -> [HTTPCookie] {
        #if canImport(WebKit)
        await dataStore.httpCookieStore.allCookies()
        #else
        HTTPCookieStorage.shared.cookies ?? []
        #endif
    }
}

#endif
