/*
 Hypnos - Depth Pipeline Spike (Settings → Developer)

 Runs `DepthPipelineSpike` against a video from Documents/Videos and shows
 its lines on device, with a Copy button to get them off the headset. The
 numbers it produces — per-model inference time, the cost of the offline
 refinement chain if run live, and how far ahead `AVPlayerItemVideoOutput`
 serves frames — are the inputs to the lookahead-buffered realtime fake-3D
 design; they are device facts that cannot be derived from code, which is why
 this lives in the app rather than in a test target.
 */

import RAVEMedia
import SwiftUI

struct DepthPipelineSpikeSection: View {
    @State private var videos: [URL] = []
    @State private var selected: URL?
    @State private var lines: [String] = []
    @State private var isRunning = false

    /// Containers AVAssetReader can open. WebM/MKV never decode natively on
    /// visionOS (see the video architecture notes), so they would only report
    /// a failed decode.
    private static let readableExtensions: Set<String> = ["mp4", "mov", "m4v"]

    var body: some View {
        Section("Depth Pipeline Spike") {
            if videos.isEmpty {
                Text("Put an MP4/MOV in Documents/Videos (Files app → Convolution → Videos) to have something to measure against.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Picker("Video", selection: $selected) {
                    ForEach(videos, id: \.self) { url in
                        Text(url.lastPathComponent).tag(Optional(url))
                    }
                }
                .pickerStyle(.menu)
            }

            Button {
                run()
            } label: {
                Label(isRunning ? "Running…" : "Run Spike", systemImage: "stopwatch")
            }
            .disabled(isRunning || selected == nil)

            if isRunning, let last = lines.last {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(last)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            if !lines.isEmpty {
                platformDisclosureGroup("Results") {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.caption.monospaced())
                            .selectableText()
                    }
                    // No system pasteboard on tvOS — nothing else on the
                    // Siri Remote to paste into anyway. This whole developer
                    // diagnostic section isn't part of the tvOS root UI (see
                    // Hypnos/CLAUDE.md "tvOS").
                    #if !os(tvOS)
                    Button {
                        UIPasteboard.general.string = lines.joined(separator: "\n")
                    } label: {
                        Label("Copy Results", systemImage: "doc.on.doc")
                    }
                    #endif
                }
            }

            Text("Measures on this device: depth inference time per installed model, the GPU cost of running the offline edge-aware refinement live, and how many frames ahead of the display AVPlayerItemVideoOutput will serve. Results also go to the Console tab.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .task { refreshVideos() }
    }

    private func refreshVideos() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: LocalMediaSource.videosDirectory, includingPropertiesForKeys: nil)) ?? []
        videos = urls
            .filter { Self.readableExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if selected == nil || !videos.contains(selected!) {
            selected = videos.first
        }
    }

    private func run() {
        guard let selected else { return }
        isRunning = true
        lines = ["Starting…"]
        Task {
            await DepthPipelineSpike.run(videoURL: selected) { line in
                Task { @MainActor in
                    if lines == ["Starting…"] { lines = [] }
                    lines.append(line)
                }
            }
            isRunning = false
        }
    }
}
