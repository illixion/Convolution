/*
 Hypnos - Video Window: the Audio menu

 A video with more than one audio track (an MKV's languages, a commentary,
 an MP4 or HLS master with several) offers them in the control strip's
 Audio menu. They come from one of two places:

 - the player: the item's audible media-selection options (a file played
   directly, the on-device remux's renditions, YouTube's master), switched
   in place;
 - the server, for a Library title Jellyfin remuxes or transcodes: that
   stream carries the one audio stream `AudioStreamIndex` asked for, so a
   pick asks for a new stream at the playhead, as a quality change does,
   and is kept through later quality changes.

 The stereo players (AI 3D, live 3D) lend their AVPlayer
 (`noteStereoAudioPlayer`), so their tracks are offered the same way. tvOS
 has AVKit's own menu.

 A remux's Stable Audio copies ("English (Stable)", `StableAudioSetting`)
 are not listed: each is paired with its track by name, and the volume
 popover's switch picks between the two (`setStableAudio`). Picking a track
 here plays its copy while the switch is on.
 */

import AVFoundation
import DebugTrace
import Foundation
import MatroskaRemux

/// One entry of the Audio menu.
struct VideoAudioTrack: Identifiable, Hashable {
    enum ID: Hashable {
        /// The player's audible option at this position.
        case player(Int)
        /// The Library file's audio stream with this index.
        case server(Int)
    }

    let id: ID
    let title: String
}

extension VideoWindowModel {
    /// Lists the tracks again: the player or the stream changed.
    func refreshAudioTracks() {
        audioTracksTask?.cancel()
        let player = audioPlayer
        let itemId = libraryItemId
        let stream = video.streamURL
        audioTracksTask = Task { [weak self] in
            // The server's tracks, when what plays carries only one of them.
            if let itemId, JellyfinLibrary.isServerStream(stream), let library = LibraryService.current() {
                let tracks: [LibraryAudioTrack]
                if let known = self?.libraryAudioTracks, known.itemId == itemId {
                    tracks = known.tracks
                } else {
                    tracks = await library.audioTracks(itemId: itemId)
                    self?.libraryAudioTracks = (itemId, tracks)
                }
                guard !Task.isCancelled, let self, self.libraryItemId == itemId else { return }
                if tracks.count > 1 {
                    let playing = JellyfinLibrary.audioStreamIndex(ofStream: self.video.streamURL)
                        ?? tracks.first(where: \.isDefault)?.index ?? tracks.first?.index
                    self.audioTracks = tracks.map { VideoAudioTrack(id: .server($0.index), title: $0.menuTitle) }
                    self.selectedAudioTrack = playing.map { .server($0) }
                    self.stableAudioPairs = [:]
                    return
                }
            }
            guard let self else { return }
            guard let item = player?.currentItem,
                  let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
                  !Task.isCancelled, self.audioPlayer === player
            else {
                if !Task.isCancelled {
                    self.stableAudioPairs = [:]
                    self.setAudioTracks([], selected: nil)
                }
                return
            }
            let options = group.options
            var titles: [String] = []
            for (number, option) in options.enumerated() {
                titles.append(await Self.title(of: option, number: number + 1))
            }
            guard !Task.isCancelled, self.audioPlayer === player else { return }
            let pairs = Self.stablePairs(titles)
            let copies = Set(pairs.values)
            let tracks = options.indices.filter { !copies.contains($0) }
                .map { VideoAudioTrack(id: .player($0), title: titles[$0]) }
            var selected = item.currentMediaSelection.selectedMediaOption(in: group)
                .flatMap { options.firstIndex(of: $0) }
            self.stableAudioPairs = pairs
            // The switch decides between a track and its copy, whichever
            // the player started on.
            if let playing = selected, let wanted = self.stableAudioCounterpart(of: playing), wanted != playing {
                item.select(options[wanted], in: group)
                AppLogger.videoWindow.info("Stable Audio \(self.stableAudioOn ? "on" : "off", privacy: .public): switched to option \(wanted + 1, privacy: .public) of \(options.count, privacy: .public)")
                selected = wanted
            }
            let shown = selected.map { playing in pairs.first { $0.value == playing }?.key ?? playing }
            self.setAudioTracks(tracks.count > 1 ? tracks : [], selected: shown.map { .player($0) })
        }
    }

    /// The player whose audio options are offered: the native renderer's,
    /// else the stereo engine's.
    var audioPlayer: AVPlayer? { nativePlayer ?? stereoAudioPlayer }

    /// Whether what plays has Stable Audio copies to switch to.
    var offersStableAudio: Bool { !stableAudioPairs.isEmpty }

    /// Each track's position paired with its Stable Audio copy's, by name
    /// (a copy is its track's name and `AudioRendition.stableSuffix`).
    static func stablePairs(_ titles: [String]) -> [Int: Int] {
        let suffix = AudioRendition.stableSuffix
        var pairs: [Int: Int] = [:]
        for (copy, title) in titles.enumerated() where title.hasSuffix(suffix) {
            let name = String(title.dropLast(suffix.count))
            if let track = titles.indices.first(where: { titles[$0] == name && pairs[$0] == nil }) {
                pairs[track] = copy
            }
        }
        return pairs
    }

    /// The option that should play instead of `option` with the switch as
    /// it is, if not `option` itself.
    func stableAudioCounterpart(of option: Int) -> Int? {
        if stableAudioOn { return stableAudioPairs[option] }
        return stableAudioPairs.first { $0.value == option }?.key
    }

    /// The volume popover's switch: plays each track's Stable copy, or the
    /// track, from here on, in every video.
    func setStableAudio(_ on: Bool) {
        stableAudioOn = on
        StableAudioSetting.isOn = on
        guard let item = audioPlayer?.currentItem else { return }
        Task {
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
                  let playing = item.currentMediaSelection.selectedMediaOption(in: group)
                    .flatMap({ group.options.firstIndex(of: $0) }),
                  let wanted = stableAudioCounterpart(of: playing) else { return }
            item.select(group.options[wanted], in: group)
            AppLogger.videoWindow.info("Stable Audio \(on ? "on" : "off", privacy: .public): option \(wanted + 1, privacy: .public) of \(group.options.count, privacy: .public)")
        }
    }

    private func setAudioTracks(_ tracks: [VideoAudioTrack], selected: VideoAudioTrack.ID?) {
        if audioTracks != tracks { audioTracks = tracks }
        if selectedAudioTrack != selected { selectedAudioTrack = selected }
    }

    /// The viewer picked `track` from the Audio menu.
    func selectAudioTrack(_ track: VideoAudioTrack) {
        guard track.id != selectedAudioTrack else { return }
        switch track.id {
        case .player(let number):
            guard let item = audioPlayer?.currentItem else { return }
            selectedAudioTrack = track.id
            // With Stable Audio on, the track's copy plays.
            let option = stableAudioOn ? stableAudioPairs[number] ?? number : number
            Task {
                guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
                      group.options.indices.contains(option) else { return }
                item.select(group.options[option], in: group)
                AppLogger.videoWindow.info("Audio track \(number + 1, privacy: .public) of \(group.options.count, privacy: .public) chosen")
            }
        case .server(let index):
            guard let itemId = libraryItemId else { return }
            selectedAudioTrack = track.id
            libraryAudioStreamIndex = (itemId, index)
            AppLogger.videoWindow.info("Library audio stream \(index, privacy: .public) chosen")
            switchStream(to: streamLevel, reason: "audio track")
        }
    }

    /// The audio stream picked for this Library title, if one was.
    func chosenLibraryAudioStream(itemId: String) -> Int? {
        guard let chosen = libraryAudioStreamIndex, chosen.itemId == itemId else { return nil }
        return chosen.index
    }

    /// "English", "Commentary", "English, Commentary", "Track 2": the
    /// option's language and its own name, when it has them. AVFoundation's
    /// display name says "Unknown language" for an option without one.
    static func title(of option: AVMediaSelectionOption, number: Int) async -> String {
        let language = option.locale != nil || option.extendedLanguageTag != nil ? option.displayName : nil
        let titleItem = AVMetadataItem.metadataItems(from: option.commonMetadata, filteredByIdentifier: .commonIdentifierTitle)
            .first
        let name = try? await titleItem?.load(.stringValue)
        // A name that already starts with the language ("English (Stable)")
        // stands alone.
        if let language, let name, !language.isEmpty, name.hasPrefix(language) { return name }
        let named = [language, name == language ? nil : name].compactMap { $0 }.filter { !$0.isEmpty }
        return named.isEmpty ? "Track \(number)" : named.joined(separator: ", ")
    }
}
