/*
 Hypnos - AI 3D model pre-warming

 When the user is somewhere AI 3D opens by default (Settings → "AI 3D for All
 Videos", a default photo viewing mode of AI 3D, a slideshow in AI 3D), the
 first picture or video used to pay for loading the depth model. Each place
 that can open AI 3D declares its intent here as an owner (a main window on a
 tab, a photo window, a video window, a slideshow) and the roles it expects to
 need; the depth model warmer (Vergence) loads lazily and keeps those models
 resident.

 Owners come and go quickly (tab hopping, gallery swipes), so this only
 diffs leases per owner and never releases-then-retakes a role; the warmer's
 dwell and grace times absorb the rest. See `DepthModelWarmer`.
 */

import Foundation
import RAVEMedia

@MainActor
final class AI3DWarmup {
    static let shared = AI3DWarmup()

    private var owners: [ObjectIdentifier: [DepthModelRole: DepthModelWarmer.Lease]] = [:]

    private init() {}

    /// `owner`'s current need: the roles to keep warm, empty for none.
    func setIntent(_ owner: AnyObject, roles: Set<DepthModelRole>) {
        let key = ObjectIdentifier(owner)
        var held = owners[key] ?? [:]
        for role in held.keys where !roles.contains(role) {
            held[role]?.release()
            held[role] = nil
        }
        for role in roles where held[role] == nil {
            held[role] = DepthModelWarmer.shared.lease(role: role)
        }
        owners[key] = held.isEmpty ? nil : held
    }

    func clearIntent(_ owner: AnyObject) {
        setIntent(owner, roles: [])
    }

    // MARK: - What each place needs

    /// Stills (photo viewer, slideshows, thumbnails) infer with the
    /// pre-process model; video plays on the real-time one.
    static let stillRole: DepthModelRole = .preprocess
    static let videoRole: DepthModelRole = .realtime

    /// The roles a main window on `tab` is likely to open, given the user's
    /// defaults. Tabs that open nothing AI-3D-capable want nothing.
    static func roles(forTab tab: Tab, appModel: AppModel) -> Set<DepthModelRole> {
        var roles: Set<DepthModelRole> = []
        let stills = appModel.defaultImageViewingMode == .aiDepth
        let video = appModel.defaultRealtimePseudo3D
        switch tab {
        case .pictures:
            if stills { roles.insert(stillRole) }
        case .videos, .library:
            if video { roles.insert(videoRole) }
        #if HYPNOS_YOUTUBE
        case .youtube:
            if video { roles.insert(videoRole) }
        #endif
        case .albums, .filters:
            // Either kind of container can be opened from here.
            if stills { roles.insert(stillRole) }
            if video { roles.insert(videoRole) }
        case .windows, .settings, .console:
            break
        }
        return roles
    }
}
