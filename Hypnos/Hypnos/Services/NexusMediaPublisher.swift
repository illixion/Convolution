//
//  NexusMediaPublisher.swift
//  Hypnos
//
//  What the film player tells the other modules of Nexus, through RAVEModuleBus: what is playing
//  and where it is, the subtitle line as it comes due, and the transport the others may use (play,
//  pause, skip). Another module (the character, watching along) reads these without knowing this
//  app exists, and everything here is gated by the bus: its actions are validated and its feeds
//  carry a privacy label. Compiled only into Nexus's framework build (`NEXUS_MODULE`); the
//  standalone app has no other module to tell. See docs/nexus-module.md.
//
//  The film player is the one source so far; video windows are not published yet.
//

#if os(visionOS) && NEXUS_MODULE

import Foundation
import RAVEFilm
import RAVEMediaCore
import RAVEModuleBus

@MainActor
final class NexusMediaPublisher: RAVEMediaControlling {
    static let moduleID = "hypnos"

    private let session = FilmSession.shared
    private let bus: RAVEModuleBus
    private var task: Task<Void, Never>?
    private var registered = false
    /// The cue last published, so a line is told once as it comes due.
    private var lastCue: Double?

    init(bus: RAVEModuleBus = .shared) { self.bus = bus }

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        withdraw()
    }

    // MARK: Publishing

    private func tick() {
        guard let item = session.loadedItem, session.isPlayerOpen else {
            withdraw()
            return
        }
        if !registered {
            RAVEMediaActions.register(on: bus, module: Self.moduleID, controller: self)
            registered = true
        }
        let player = session.player
        bus.publish(RAVEMediaFeeds.nowPlaying,
                    RAVENowPlaying(title: item.name, year: item.productionYear, kind: .film,
                                   position: player.currentTime, duration: player.duration,
                                   isPlaying: player.isPlaying),
                    from: Self.moduleID)
        publishCue(at: player.currentTime)
        publishScreen()
    }

    /// Where Big Screen is, so a module that wants to watch it can sit facing it. The HUD follows the head and the
    /// window is a window, so neither is a place to sit toward.
    private func publishScreen() {
        let cinema = Cinema.shared
        guard cinema.mode == .bigScreen, cinema.screenAttached, let pose = cinema.screenPose else { return }
        let width = cinema.pictureWidth
        bus.publish(RAVEMediaFeeds.screen,
                    RAVESpaceObject(kind: "screen", transform: pose, size: SIMD2(width, width / max(cinema.hudAspect, 0.1))),
                    from: Self.moduleID)
    }

    /// The line showing at `time`, once.
    private func publishCue(at time: Double) {
        guard let track = session.subtitles.cues else { return }
        let trackTime = session.subtitles.cueTime(forFilmTime: time)
        guard let cue = track.cues.last(where: { $0.start <= trackTime && trackTime < $0.end }),
              cue.start != lastCue else { return }
        lastCue = cue.start
        let text = String(cue.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        bus.publish(RAVEMediaFeeds.subtitle,
                    RAVEMediaCue(text: text, start: cue.start, end: cue.end),
                    from: Self.moduleID)
    }

    /// The film closed: its feeds and actions go, so nobody reads a film that isn't there.
    private func withdraw() {
        guard registered else { return }
        bus.retire(module: Self.moduleID)
        registered = false
        lastCue = nil
    }

    // MARK: RAVEMediaControlling

    var isPlaying: Bool { session.player.isPlaying }
    var hasMedia: Bool { session.loadedItem != nil && session.isPlayerOpen }
    var canPlayNext: Bool { false }

    func play() { session.player.play() }
    func pause() { session.player.pause() }

    func skip(by seconds: TimeInterval) {
        let player = session.player
        let target = player.currentTime + seconds
        player.seek(to: min(max(target, 0), player.duration > 0 ? player.duration : target))
    }

    func playNext() {}
}

#endif
