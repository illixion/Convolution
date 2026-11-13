/*
 Hypnos - which object-audio formats this build asks the plugin for

 The Atmos Objects plugin decodes TrueHD Atmos and E-AC-3 JOC for every
 client, and DTS:X only for a client that lists it in `objectCodecs`: a
 sideload build made with `DTSX_CONDITION=HYPNOS_DTSX`. A submission build
 never lists it, so the plugin never offers it a DTS:X track, and a film whose
 only object audio is DTS:X plays there as it always did. The decoding is
 the server's either way (the plugin runs harletty); nothing DTS is
 compiled into the app.

 Every request under `AtmosObjects/` carries the list: the film player's
 (`FilmServerClient.extraQuery`), the Library's routing probe, and downloads.
 A plugin from before DTS:X ignores it.
 */

import Foundation
import RAVEFilm

enum ObjectAudioEdition {
    /// The plugin's names for the formats this build may play.
    static var codecs: [String] {
        #if HYPNOS_DTSX
        ["truehd", "eac3", "dtsx"]
        #else
        ["truehd", "eac3"]
        #endif
    }

    static var queryItem: URLQueryItem {
        URLQueryItem(name: "objectCodecs", value: codecs.joined(separator: ","))
    }

    /// `query` plus the list, for a request to `path` on the Jellyfin server.
    static func query(_ query: [URLQueryItem], forPath path: String) -> [URLQueryItem] {
        path.hasPrefix("AtmosObjects/") ? query + [queryItem] : query
    }
}

extension FilmServerClient {
    /// The client with this build's object-audio formats on every request.
    mutating func applyEdition() {
        extraQuery = [ObjectAudioEdition.queryItem]
    }
}
