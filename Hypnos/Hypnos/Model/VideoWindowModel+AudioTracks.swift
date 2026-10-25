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

 The stereo players (AI 3D, live 3D) own their AVPlayer, so only a
 server's tracks are offered while one plays. tvOS has AVKit's own menu.
 */

import AVFoundation
import DebugTrace
import Foundation

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
        let player = nativePlayer
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
                    return
                }
            }
            guard let self else { return }
            guard let item = player?.currentItem,
                  let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
                  !Task.isCancelled, self.nativePlayer === player
            else {
                if !Task.isCancelled { self.setAudioTracks([], selected: nil) }
                return
            }
            let options = group.options
            var tracks: [VideoAudioTrack] = []
            for (number, option) in options.enumerated() {
                tracks.append(VideoAudioTrack(id: .player(number), title: await Self.title(of: option, number: number + 1)))
            }
            guard !Task.isCancelled, self.nativePlayer === player else { return }
            let selected = item.currentMediaSelection.selectedMediaOption(in: group)
                .flatMap { options.firstIndex(of: $0) }
            self.setAudioTracks(tracks.count > 1 ? tracks : [], selected: selected.map { .player($0) })
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
            guard let item = nativePlayer?.currentItem else { return }
            selectedAudioTrack = track.id
            Task {
                guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
                      group.options.indices.contains(number) else { return }
                item.select(group.options[number], in: group)
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
        let named = [language, name == language ? nil : name].compactMap { $0 }.filter { !$0.isEmpty }
        return named.isEmpty ? "Track \(number)" : named.joined(separator: ", ")
    }
}
