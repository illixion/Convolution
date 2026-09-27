/*
 Hypnos - dev/test-only Jellyfin sign-in trigger (DEBUG only)

 A plain Keychain secret (the API key) has no `-UITestDefault key=value`
 route in from a launch argument the way a UserDefaults-backed setting
 does (see `FilmSession.apiKey`'s UserDefaults→Keychain migration for that
 half of the story). Signing in for real needs no secret injection at all
 though — it just needs the same username/password a person would type in
 Settings — so this triggers that flow from environment variables instead,
 for driving a simulator against the disposable dev Jellyfin
 (`scripts/dev-jellyfin.sh`) without a build-and-inspect step in between.

 Reads `HYPNOS_DEV_JELLYFIN_SIGNIN_USER`/`_PASS` and signs in against
 whatever server `FilmSession.server` already resolved to (typically set via
 `-UITestDefault filmPlayer.jellyfinServer=...` alongside this). No-op when
 either variable is unset, so an ordinary launch is unaffected.
 */

#if DEBUG

import Foundation
import os

enum DevJellyfinSignIn {
    static func performIfRequested() {
        guard let username = ProcessInfo.processInfo.environment["HYPNOS_DEV_JELLYFIN_SIGNIN_USER"],
              let password = ProcessInfo.processInfo.environment["HYPNOS_DEV_JELLYFIN_SIGNIN_PASS"],
              !username.isEmpty, !password.isEmpty
        else { return }

        Task { @MainActor in
            let server = FilmSession.shared.server.trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: server) else {
                AppLogger.app.error("DevJellyfinSignIn: server URL didn't parse")
                return
            }
            await JellyfinAuth.shared.signIn(serverURL: url, username: username, password: password)
        }
    }
}

#endif
