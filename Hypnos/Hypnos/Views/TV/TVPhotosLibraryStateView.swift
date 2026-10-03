/*
 Hypnos - tvOS Photos library empty state

 The Pictures/Videos tabs' "nothing to show" message when the Photos library
 source is in force. Mirrors the spirit of `PhotoLibraryStateView`
 (visionOS/iOS, `Views/MediaLibraryStateView.swift`) but without any of its
 touch UI — no inline server-connect form, nothing keyboard-shaped — since
 none of that reads well from six feet with a Siri Remote. tvOS keeps almost
 nothing locally, so an Apple TV that has never had iCloud Photos turned on
 is the common case, not an edge case: the message says exactly where to
 enable it (Settings → Users and Accounts → iCloud) rather than assuming the
 user knows this is even a per-device toggle.
 */

#if os(tvOS)

import Photos
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import Foundation
import ImageIO

struct TVPhotosLibraryStateView: View {
    enum Kind {
        case pictures
        case videos

        var noun: String { self == .pictures ? "pictures" : "videos" }
        var symbol: String { self == .pictures ? "photo.on.rectangle.angled" : "video.slash" }
    }

    let kind: Kind
    let status: PHAuthorizationStatus
    var onRequestAccess: () -> Void = {}

    var body: some View {
        switch status {
        case .notDetermined:
            ContentUnavailableView {
                Label("Show Your \(kind == .pictures ? "Pictures" : "Videos")?", systemImage: kind.symbol)
            } description: {
                Text("Convolution can show the \(kind.noun) in this Apple TV's iCloud Photos library.")
            } actions: {
                Button("Allow Photos Access", action: onRequestAccess)
            }
        case .denied, .restricted:
            ContentUnavailableView {
                Label("Photos Access Off", systemImage: "lock.fill")
            } description: {
                Text("Enable iCloud Photos in Settings → Users and Accounts → iCloud on this Apple TV, or use Stash / Nextcloud / Local Files instead.")
            } actions: {
                Button("Open Settings", action: openSettings)
            }
        default:
            // Readable (authorized or limited) but empty — Apple TV has no
            // camera roll of its own, so this is the ordinary case for a
            // fresh Apple TV signed into an account with iCloud Photos off,
            // not a failure to explain away.
            ContentUnavailableView(
                "No \(kind == .pictures ? "Pictures" : "Videos")",
                systemImage: kind.symbol,
                description: Text("Turn on iCloud Photos in Settings → Users and Accounts → iCloud so this Apple TV can show your library, or connect Stash / Nextcloud instead.")
            )
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

#endif
