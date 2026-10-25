/*
 What the players' audio menus show for the remux's renditions:
 AVFoundation's `displayName` for each option of the audible group, read
 from the session served over loopback HTTP the way the app serves it.
 AVKit's menus list that name.
 */

#if canImport(AVFoundation) && canImport(Network) && os(macOS)

import AVFoundation
import Foundation
import Testing
@testable import MatroskaRemux

@Suite("Audio menu labels", .serialized)
struct RenditionLabelTests {
    struct Label: Equatable, CustomStringConvertible {
        /// `displayName(with:)` in English.
        var shown: String
        /// The common title metadata: the rendition's NAME.
        var title: String?
        var description: String { "\(shown) [\(title ?? "-")]" }
    }

    static func labels(_ session: RemuxSession, play: Bool = false) async throws -> [Label] {
        let (server, base) = try await LoopbackServer.start(session)
        defer { server.stop() }
        let asset = AVURLAsset(url: base.appendingPathComponent("master.m3u8"))
        let group = try #require(try await asset.loadMediaSelectionGroup(for: .audible))
        var labels: [Label] = []
        for option in group.options {
            let title = AVMetadataItem.metadataItems(from: option.commonMetadata, filteredByIdentifier: .commonIdentifierTitle).first
            labels.append(Label(shown: option.displayName(with: Locale(identifier: "en")),
                                title: try await title?.load(.stringValue)))
        }
        if play {
            // The player takes it: ready, and switches to the last option.
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.isMuted = true
            for _ in 0 ..< 100 where item.status == .unknown { try await Task.sleep(for: .milliseconds(50)) }
            #expect(item.status == .readyToPlay, "\(item.error.map { "\($0)" } ?? "")")
            if let last = group.options.last {
                item.select(last, in: group)
                #expect(item.currentMediaSelection.selectedMediaOption(in: group) == last)
            }
            player.replaceCurrentItem(with: nil)
        }
        return labels
    }

    /// Languages the file states are shown as languages.
    @Test func statedLanguages() async throws {
        let labels = try await Self.labels(try await Fixtures.open("two-audio.mkv"), play: true)
        #expect(labels == [Label(shown: "English", title: "Main Stereo"), Label(shown: "French", title: "Commentaire")])
    }

    /// No language: codec and layout, not "Unknown".
    @Test func noLanguage() async throws {
        #expect(try await Self.labels(try await Fixtures.open("ac3-51.mkv"), play: true)
            == [Label(shown: "AC-3 5.1", title: "AC-3 5.1")])
        var writer = try await MatroskaTestWriter.load(try Fixtures.data("two-audio.mkv"))
        for i in [1, 2] {
            writer.tracks[i].language = "und"
            writer.tracks[i].languageBCP47 = nil
            writer.tracks[i].name = nil
        }
        #expect(try await Self.labels(try await RemuxSession.open(source: DataByteSource(writer.write())))
            == [Label(shown: "AAC Mono", title: "AAC Mono"), Label(shown: "AC-3 Stereo", title: "AC-3 Stereo")])
        // A track's own name is shown as it is.
        writer.tracks[2].name = "Director's commentary"
        #expect(try await Self.labels(try await RemuxSession.open(source: DataByteSource(writer.write())))
            .last == Label(shown: "Director's commentary", title: "Director's commentary"))
        // A name that reads as a language code isn't taken for one.
        writer.tracks[2].name = "de"
        #expect(try await Self.labels(try await RemuxSession.open(source: DataByteSource(writer.write())))
            .last == Label(shown: "de (Stereo)", title: "de"))
    }

    /// Two tracks in one language: the default shows the language, the
    /// other its name, so the menu doesn't list "English" twice.
    @Test func sharedLanguage() async throws {
        var writer = try await MatroskaTestWriter.load(try Fixtures.data("two-audio.mkv"))
        for i in [1, 2] {
            writer.tracks[i].language = "eng"
            writer.tracks[i].languageBCP47 = "en"
        }
        writer.tracks[1].name = "Main"
        writer.tracks[2].name = "Commentary"
        #expect(try await Self.labels(try await RemuxSession.open(source: DataByteSource(writer.write())), play: true)
            == [Label(shown: "English", title: "Main"), Label(shown: "Commentary", title: "Commentary")])
        writer.tracks[1].name = nil
        writer.tracks[2].name = nil
        #expect(try await Self.labels(try await RemuxSession.open(source: DataByteSource(writer.write())))
            == [Label(shown: "English", title: "English (Mono)"), Label(shown: "English (Stereo)", title: "English (Stereo)")])
    }

    /// What the package hands the app for its own menu.
    @Test func renditionsForAnAppMenu() async throws {
        let session = try await Fixtures.open("two-audio.mkv")
        #expect(session.audioRenditions == [
            AudioRendition(trackNumber: 2, name: "Main Stereo", language: "en", playlistLanguage: "en", codec: "AAC",
                           codecs: "mp4a.40.2", channels: 1, layout: "Mono", hasObjectAudio: false, isDefault: true,
                           uri: "audio-2.m3u8"),
            AudioRendition(trackNumber: 3, name: "Commentaire", language: "fr", playlistLanguage: "fr", codec: "AC-3",
                           codecs: "ac-3", channels: 2, layout: "Stereo", hasObjectAudio: false, isDefault: false,
                           uri: "audio-3.m3u8"),
        ])
    }
}

#endif
