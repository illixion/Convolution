/*
 Hypnos - Library Source

 Which library the Pictures and Videos tabs are browsing.

 Distinct from `MediaSource`, which records where an individual item came from.
 This is the app-level choice of what to show, and it exists because the two
 were previously conflated: the source was inferred from whether
 `stashServerURL` happened to be non-empty, which made a configured server
 silently suppress the photo library altogether. There was no way to look at
 your own photos without clearing the server setting.
 */

import Foundation

enum LibrarySource: String, Codable, CaseIterable, Sendable {
    /// The device photo library.
    case photos
    /// A Stash server.
    case stash
    /// Files placed in the app's own Documents folder.
    case local
    /// A Nextcloud server's files, under a chosen root folder.
    case nextcloud

    var symbolName: String {
        switch self {
        case .photos: return "photo.artframe"
        case .stash:  return "archivebox"
        // Matches the Files app's "On My <device>" icon — the same
        // on-device-storage idea this source is.
        case .local:  return Self.thisDeviceSymbol
        case .nextcloud: return "cloud"
        }
    }

    /// The SF Symbol for the device the app is running on.
    ///
    /// iPhone and iPad share a binary, so the model identifier tells them
    /// apart; that keeps this off the main actor, unlike `UIDevice`.
    private static let thisDeviceSymbol: String = {
        #if os(visionOS)
        return "vision.pro"
        #elseif os(tvOS)
        return "appletv"
        #elseif os(macOS)
        return "desktopcomputer"
        #else
        var model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        if model.isEmpty {
            var info = utsname()
            uname(&info)
            model = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        return model.hasPrefix("iPad") ? "ipad" : "iphone"
        #endif
    }()

    var displayName: String {
        switch self {
        case .photos: return "Photos"
        case .stash:  return "Stash"
        case .local:  return "Local Files"
        case .nextcloud: return "Nextcloud"
        }
    }

    /// Whether the Filters tab has anything to offer — tags, performers,
    /// studios, galleries.
    ///
    /// Asked by the tab bar (both chromes) and by the redirect that rescues a
    /// window already sitting on Filters when the library changes. Those three
    /// each tested `!= .local` before, which is precisely the shape that
    /// silently does the wrong thing the moment a second metadata-less library
    /// exists — as Nextcloud, whose WebDAV view is a plain file tree, does.
    var offersFilters: Bool {
        switch self {
        case .photos, .stash: return true
        case .local, .nextcloud: return false
        }
    }

    /// Whether the Albums tab has anything to show: a container grid for the
    /// libraries with real containers, or Local's folder browser.
    ///
    /// Nextcloud is a file tree as well, but has no browser yet — its root is
    /// chosen in Settings instead — so the tab would open on nothing.
    var offersAlbums: Bool {
        switch self {
        case .photos, .stash, .local: return true
        case .nextcloud: return false
        }
    }
}
