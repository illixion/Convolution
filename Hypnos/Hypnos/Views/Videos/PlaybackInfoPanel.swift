/*
 Hypnos - the playback info panel

 A small semi-opaque card in the video's top-right corner, with the rest of
 the chrome: how the picture gets here and what it is.

     ✓ Direct Play                     ⚠ Server Transcode  Jellyfin
     1920×1080 · 23.976 fps · HDR10    1920×1080 · 23.976 fps · SDR
                                       The remux on this device declined it: …

 Three lines at most. The first is the route, its symbol tinted by how it
 came about: green for the original played as it is, neutral for a
 fallback someone chose (a quality cap, AI 3D's 1080p), orange when
 something failed on the way. The second is the picture: size, rate and
 dynamic range, the range as the frames say it (named with the source's
 metadata: HDR10+, Dolby Vision 8.1). The third, only when it matters, is
 why: the first reason, or what the picture lost ("Tone-mapped from Dolby
 Vision 8.1"). A tap shows the details: what the server's encoder copies
 and converts, the file as the server read it, and every reason.
 */

import SwiftUI

struct PlaybackInfoPanel: View {
    let info: PlaybackInfo
    /// Bumped by the host to close the details (a tap on the picture).
    var dismissal = 0
    var onOpenChanged: (Bool) -> Void = { _ in }

    @State private var showsDetails = false

    var body: some View {
        Button { showsDetails.toggle() } label: { card }
            .buttonStyle(.plain)
            #if os(visionOS)
            .contentShape(.hoverEffect, .rect(cornerRadius: Self.cornerRadius))
            .hoverEffect(.highlight)
            #endif
            .accessibilityIdentifier("player.playbackInfo")
            .accessibilityLabel(accessibilityText)
            .accessibilityHint("Shows how this video plays")
            .help("Playback Info")
            #if !os(tvOS)
            .ravePlayerPopover(isPresented: $showsDetails, arrowEdge: .top) {
                PlaybackInfoDetailsView(info: info)
                    .frame(idealWidth: 440, maxWidth: 500, maxHeight: 600)
                    .presentationCompactAdaptation(.sheet)
                    .presentationDetents([.medium, .large])
                    .presentationBackgroundInteraction(.enabled)
            }
            #endif
            .onChange(of: showsDetails) { _, shown in onOpenChanged(shown) }
            .onChange(of: dismissal) { showsDetails = false }
            .onDisappear {
                if showsDetails { onOpenChanged(false) }
                showsDetails = false
            }
    }

    static let cornerRadius: CGFloat = 16

    private var card: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .imageScale(.medium)
                Text(info.route.title)
                    .font(.subheadline.weight(.semibold))
                if let server = info.server {
                    Text(server)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let readout = info.readout {
                Text(readout)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let headline = info.headline {
                Text(headline)
                    .font(.caption)
                    .foregroundStyle(info.severity == .issue ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: 340, alignment: .trailing)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.5), in: .rect(cornerRadius: Self.cornerRadius, style: .continuous))
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    private var symbol: String {
        info.severity == .issue ? "exclamationmark.triangle.fill" : info.route.symbol
    }

    private var tint: AnyShapeStyle {
        switch info.severity {
        case .issue: AnyShapeStyle(.orange)
        case .chosen: AnyShapeStyle(.secondary)
        case .normal:
            switch info.route {
            case .direct, .deviceRemux: AnyShapeStyle(.green)
            default: AnyShapeStyle(.secondary)
            }
        }
    }

    private var accessibilityText: String {
        [info.route.title, info.server, info.readout, info.headline].compactMap { $0 }.joined(separator: ", ")
    }
}

/// What the panel's tap shows.
struct PlaybackInfoDetailsView: View {
    let info: PlaybackInfo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text([info.route.title, info.server].compactMap { $0 }.joined(separator: " · "))
                            .font(.title3.weight(.semibold))
                    } icon: {
                        Image(systemName: info.severity == .issue ? "exclamationmark.triangle.fill" : info.route.symbol)
                            .foregroundStyle(info.severity == .issue ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    }
                    Text(info.route.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !info.reasons.isEmpty {
                    section("Why") {
                        ForEach(Array(info.reasons.enumerated()), id: \.offset) { _, reason in
                            Label(reason.prefix(1).uppercased() + reason.dropFirst(), systemImage: "arrow.turn.down.right")
                                .font(.callout)
                        }
                    }
                }

                section("Picture") {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                        if let picture = info.picture { row("Size", picture) }
                        if let range = info.range {
                            row("Range", range.label)
                            if let note = range.note { row("", note) }
                        }
                        if info.picture == nil, info.range == nil { row("", "Waiting for the first frame") }
                    }
                }

                if let transcode = info.transcode {
                    section("Server") {
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                            row("Video", Self.videoText(transcode))
                            row("Audio", Self.audioText(transcode))
                            if let bitrate = transcode.bitrate, bitrate > 0 {
                                row("Bitrate", String(format: "%.1f Mbps", Double(bitrate) / 1_000_000))
                            }
                            if let container = transcode.container { row("Container", container.uppercased()) }
                            if let hardware = transcode.hardwareAcceleration, hardware.lowercased() != "none" {
                                row("Encoder", hardware)
                            }
                        }
                    }
                } else if info.route.isServerConversion {
                    section("Server") {
                        Text("Waiting for the server to report its encoder.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if let source = info.source {
                    section("Source File") {
                        Text(source).font(.callout)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("player.playbackInfo.details")
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(.callout.monospacedDigit())
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func videoText(_ info: LibraryTranscodeInfo) -> String {
        let codec = info.videoCodec.map(VideoWindowModel.codecName)
        if info.isVideoDirect { return ["Copied", codec].compactMap { $0 }.joined(separator: " · ") }
        var text = "Converted to \(codec ?? "another codec")"
        if let width = info.width, let height = info.height, width > 0, height > 0 { text += " · \(width)×\(height)" }
        return text
    }

    static func audioText(_ info: LibraryTranscodeInfo) -> String {
        let codec = info.audioCodec.map(VideoWindowModel.codecName)
        let layout: String? = switch info.audioChannels {
        case 1: "Mono"
        case 2: "Stereo"
        case 6: "5.1"
        case 8: "7.1"
        case let count?: "\(count) channels"
        case nil: nil
        }
        if info.isAudioDirect { return ["Copied", codec, layout].compactMap { $0 }.joined(separator: " · ") }
        return ["Converted to \(codec ?? "another codec")", layout].compactMap { $0 }.joined(separator: " · ")
    }
}
