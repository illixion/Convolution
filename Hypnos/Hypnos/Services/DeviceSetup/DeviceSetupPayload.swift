/*
 Hypnos - what an Apple TV setup transfer carries

 Server addresses and their credentials — the things that are painful to
 type with a Siri Remote — and the library choice. Deliberately not the
 settings backup: that leaves every secret out by design (see
 `SettingsBackup.stashAPIKey`) and carries display preferences a TV has no
 use for, while this exists precisely to move the secrets.

 Credentials are copied, not re-issued: the TV uses the same Stash API key,
 Nextcloud app password and Jellyfin access token as the sender, so each
 server lists the two as one device. Jellyfin tolerates a token used from
 two devices (its own auth code allows for tokens shared with casting
 devices); it only relabels the device with whichever name last used it.

 Applying overwrites only the servers present in the payload and leaves the
 rest of the TV's configuration alone.
 */

import Foundation

struct DeviceSetupPayload: Codable, Sendable {
    struct Stash: Codable, Sendable {
        var url: String
        var apiKey: String
        var transcoding: Bool
    }

    struct Nextcloud: Codable, Sendable {
        var url: String
        var username: String
        var appPassword: String
        var root: String
    }

    struct Jellyfin: Codable, Sendable {
        struct Session: Codable, Sendable {
            var userId: String
            var userName: String
            var accessToken: String
        }

        var server: String
        var apiKey: String
        var session: Session?
    }

    var version = 1
    var librarySource: String?
    var stash: Stash?
    var nextcloud: Nextcloud?
    var jellyfin: Jellyfin?

    var isEmpty: Bool { stash == nil && nextcloud == nil && jellyfin == nil }

    /// One line per server, for both ends' confirmation text.
    var summary: [String] {
        var lines: [String] = []
        if let stash { lines.append("Stash — \(Self.host(stash.url))") }
        if let nextcloud { lines.append("Nextcloud — \(nextcloud.username) on \(Self.host(nextcloud.url))") }
        if let jellyfin {
            let who = jellyfin.session.map { "\($0.userName) on " } ?? ""
            lines.append("Jellyfin — \(who)\(Self.host(jellyfin.server))")
        }
        return lines
    }

    private static func host(_ url: String) -> String {
        URL(string: url)?.host ?? url
    }

    /// Everything this device has configured.
    @MainActor
    static func current(from appModel: AppModel) -> DeviceSetupPayload {
        var payload = DeviceSetupPayload()
        payload.librarySource = appModel.effectiveLibrarySource.rawValue
        if appModel.hasStashServer {
            payload.stash = Stash(url: appModel.stashServerURL, apiKey: appModel.stashAPIKey,
                                  transcoding: appModel.enableStashTranscoding)
        }
        if appModel.hasNextcloudServer {
            payload.nextcloud = Nextcloud(url: appModel.nextcloudServerURL, username: appModel.nextcloudUsername,
                                          appPassword: appModel.nextcloudAppPassword, root: appModel.nextcloudRoot)
        }
        let film = FilmSession.shared
        let session = JellyfinAuth.shared.session
        if !film.server.trimmingCharacters(in: .whitespaces).isEmpty, session != nil || !film.apiKey.isEmpty {
            payload.jellyfin = Jellyfin(
                server: film.server,
                apiKey: film.apiKey,
                session: session.map { Jellyfin.Session(userId: $0.userId, userName: $0.userName, accessToken: $0.accessToken) }
            )
        }
        return payload
    }

    /// Applies each server through the same setters Settings uses, so the
    /// clients rebuild live; the library choice goes last, once the source
    /// it names is available.
    @MainActor
    func apply(to appModel: AppModel) {
        if let stash {
            appModel.stashAPIKey = stash.apiKey
            appModel.stashServerURL = stash.url
            appModel.enableStashTranscoding = stash.transcoding
        }
        if let nextcloud {
            appModel.nextcloudServerURL = nextcloud.url
            appModel.nextcloudUsername = nextcloud.username
            appModel.nextcloudAppPassword = nextcloud.appPassword
            appModel.nextcloudRoot = nextcloud.root
        }
        if let jellyfin {
            let film = FilmSession.shared
            film.server = jellyfin.server
            film.apiKey = jellyfin.apiKey
            if let session = jellyfin.session {
                JellyfinAuth.shared.install(JellyfinSession(userId: session.userId, userName: session.userName,
                                                            accessToken: session.accessToken))
            } else {
                JellyfinAuth.shared.signOut()
            }
        }
        if let raw = librarySource, let source = LibrarySource(rawValue: raw),
           appModel.availableLibrarySources.contains(source) {
            appModel.librarySource = source
        }
    }
}
