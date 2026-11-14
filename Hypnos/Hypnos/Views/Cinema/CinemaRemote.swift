//
//  CinemaRemote.swift
//  Hypnos
//
//  What the forearm remote (`ForearmSleeve`) shows while a picture is in the cinema's space (HUD
//  or Big Screen): RAVE Engine's `RAVESleevePresets.mediaRemote` without its title (the picture
//  names what plays, and five rows put the last ones out of easy reach, user 2026-11-14), a seek bar, back /
//  play-pause / forward / next, and the volume, wired to whichever player owns the cinema
//  (`CinemaOwner`); then Recenter (the HUD straight ahead, the Big Screen placed in front) and
//  Window (back to the player's window), which were the left-behind window's card until the
//  window stopped showing anything in the HUD (2026-11-14).
//
//  Big Screen had no controls in the space at all (they stayed in the window, behind the
//  viewer or across the room), and the HUD's strip hides with the chrome. The sleeve is the
//  portfolio's hand-anchored HUD (RAVEEngine's CLAUDE.md, "About `RAVESleeve`").
//

#if os(visionOS)

import DebugTrace
import QuartzCore
import RAVEFilm
import RAVEPanel
import SwiftUI

@MainActor
final class CinemaRemote: SleeveRemote {
    static let shared = CinemaRemote()

    private typealias Tile = RAVESleevePresets.MediaTile

    /// Seconds Back and Forward jump.
    static let skipSeconds = 10

    /// The cinema's own tiles, under the media remote's.
    enum SpaceTile {
        static let recenter = "cinema.recenter"
        static let window = "cinema.window"
    }

    private enum SpaceAction {
        static let recenter = "cinema.recenter"
        static let window = "cinema.window"
    }

    let kind = "cinema"
    let layout: RAVESleeveLayout = {
        var page = RAVESleevePresets.mediaRemote(skipSeconds: CinemaRemote.skipSeconds, volume: true)
        page.rows.removeAll { row in row.contains { $0.id == Tile.title } }
        page.rows.append([
            RAVESleeveTile(SpaceTile.recenter, .button(RAVESleeveAction(SpaceAction.recenter)),
                           label: "Recenter", icon: "scope", span: 2),
            RAVESleeveTile(SpaceTile.window, .button(RAVESleeveAction(SpaceAction.window)),
                           label: "Window", icon: "macwindow", span: 2),
        ])
        return RAVESleeveLayout(outer: [page])
    }()

    /// Where the seek bar is being dragged to; applied when it is let go, so a
    /// drag is one seek and not one per frame.
    private var scrub: Float?
    private var scrubSeen: TimeInterval = 0
    /// The player this frame, read once in `refresh`.
    private var current: Player?

    private let logger = DebugLogger(subsystem: "com.illixion.hypnos", category: "Sleeve")

    private init() {}

    var isActive: Bool { Cinema.shared.mode.showsPicture && Player.current != nil }

    func refresh(_ wearer: RAVESleeveWearer) {
        let player = Player.current
        current = player
        guard let player else {
            for id in [Tile.progress, Tile.back, Tile.playPause, Tile.forward, Tile.next, Tile.volume] {
                set(wearer, id, RAVESleeveTileState(disabled: true))
            }
            return
        }
        let duration = player.duration
        let seekable = duration > 0
        let fraction = scrub ?? (seekable ? Float(min(max(player.time / duration, 0), 1)) : 0)
        let shownTime = scrub.map { Double($0) * duration } ?? player.time
        set(wearer, Tile.progress, RAVESleeveTileState(
            fraction: fraction,
            text: seekable ? "\(Self.clock(shownTime)) / \(Self.clock(duration))" : Self.clock(shownTime),
            disabled: !seekable))
        set(wearer, Tile.back, RAVESleeveTileState(disabled: !seekable))
        set(wearer, Tile.forward, RAVESleeveTileState(disabled: !seekable))
        set(wearer, Tile.playPause, RAVESleeveTileState(isOn: player.isPlaying, text: player.isPlaying ? "Pause" : "Play"))
        set(wearer, Tile.next, RAVESleeveTileState(disabled: !player.canPlayNext))
        set(wearer, Tile.volume, RAVESleeveTileState(fraction: Float(player.volume),
                                                     text: player.isMuted ? "Muted" : "Volume \(Int((player.volume * 100).rounded()))%"))
    }

    func handle(_ event: RAVESleeveEvent, _ wearer: RAVESleeveWearer) {
        guard let action = event.action else { return }
        let cinema = Cinema.shared
        switch (action.id, event.kind) {
        case (SpaceAction.recenter, .fired):
            logger.info("Sleeve: recenter by \(event.source.rawValue, privacy: .public)")
            cinema.placeInFront()
            return
        case (SpaceAction.window, .fired):
            guard let owner = cinema.owner else { return }
            logger.info("Sleeve: back to the window by \(event.source.rawValue, privacy: .public)")
            Task { await cinema.returnToWindow(owner) }
            return
        default:
            break
        }
        guard let player = current else { return }
        typealias Action = RAVESleevePresets.MediaAction
        switch (action.id, event.kind) {
        case (Action.play, .toggled(let play)):
            logger.info("Sleeve: \(play ? "play" : "pause", privacy: .public) by \(event.source.rawValue, privacy: .public)")
            player.setPlaying(play)
        case (Action.skip, .fired):
            guard let seconds = action.argument.flatMap(Double.init) else { return }
            logger.info("Sleeve: skip \(Int(seconds), privacy: .public) s by \(event.source.rawValue, privacy: .public)")
            player.skip(by: seconds)
        case (Action.next, .fired):
            logger.info("Sleeve: next by \(event.source.rawValue, privacy: .public)")
            player.playNext()
        case (Action.seek, .value(let fraction)):
            scrub = fraction
            scrubSeen = CACurrentMediaTime()
        case (Action.volume, .value(let fraction)):
            player.setVolume(Double(fraction))
        default:
            break
        }
    }

    func stepped(_ wearer: RAVESleeveWearer) {
        // The seek bar let go: one seek, to where it was left.
        guard let fraction = scrub else { return }
        let held = wearer.snapshot?.tiles.first { $0.tile.id == Tile.progress }?.isPressed ?? false
        if !held, CACurrentMediaTime() - scrubSeen > 0.12 {
            scrub = nil
            current?.seek(toFraction: Double(fraction))
        }
    }

    func released() {
        scrub = nil
        current = nil
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded())
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - The player behind the remote

/// The cinema's owner as a transport: the film player, or the video window whose
/// picture is in the space. The same calls its own controls make.
@MainActor
private struct Player {
    let isPlaying: Bool
    let time: Double
    let duration: Double
    let volume: Double
    let isMuted: Bool
    let canPlayNext: Bool
    let setPlaying: (Bool) -> Void
    let skip: (Double) -> Void
    let seek: (Double) -> Void
    let setVolume: (Double) -> Void
    let playNext: () -> Void

    func skip(by seconds: Double) { skip(seconds) }
    func seek(toFraction fraction: Double) { if duration > 0 { seek(fraction * duration) } }

    static var current: Player? {
        let cinema = Cinema.shared
        switch cinema.owner {
        case .film:
            let session = FilmSession.shared
            guard let item = session.loadedItem else { return nil }
            let player = session.player
            return Player(
                isPlaying: player.isPlaying,
                time: player.currentTime, duration: player.duration,
                volume: Double(player.volume), isMuted: false, canPlayNext: false,
                setPlaying: { $0 ? player.play() : player.pause() },
                skip: { seconds in
                    let target = player.currentTime + seconds
                    player.seek(to: min(max(target, 0), player.duration > 0 ? player.duration : target))
                },
                seek: { player.seek(to: $0) },
                setVolume: { value in
                    player.volume = Float(value)
                    PlayerVolume.saved = value
                },
                playNext: {})
        case .video(let id):
            guard let model = cinema.hudVideoModel, ObjectIdentifier(model) == id else { return nil }
            return Player(
                isPlaying: !model.isPaused,
                time: model.currentTime, duration: model.duration,
                volume: model.isMuted ? 0 : model.volume, isMuted: model.isMuted,
                canPlayNext: model.hasNextVideo,
                setPlaying: { [weak model] play in
                    guard let model, model.isPaused == play else { return }
                    model.togglePlayPause()
                },
                skip: { [weak model] in model?.seek(by: $0) },
                seek: { [weak model] in model?.endScrub(at: $0) },
                setVolume: { [weak model] value in
                    guard let model else { return }
                    model.setVolume(value)
                    // Turning the volume up is asking to hear it.
                    if model.isMuted, value > 0 { model.toggleMute() }
                },
                playNext: { [weak model] in model?.nextVideo() })
        case nil:
            return nil
        }
    }
}

#endif
