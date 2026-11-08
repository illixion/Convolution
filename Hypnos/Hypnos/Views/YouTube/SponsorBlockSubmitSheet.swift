/*
 Hypnos - SponsorBlock segment editor (sideload builds, not tvOS)

 Sending a segment is a deliberate act, in two steps:

 1. **Edit.** Each end is marked like an A-B loop point (from the playhead,
    or from an engaged A-B loop), then shown as the frame at that time, with
    coarse and fine steps that refresh the frame. "Preview the cut" plays the
    run-up, jumps from start to end and plays on, as a viewer would see it.
 2. **Review.** Both frames large, the times, the category and what a send
    means. Submit is disabled until both frames have loaded and the cut has
    been previewed once, and it is a different button from anything above.

 SponsorBlock allows apps to submit but forbids automating the timings, so
 nothing here suggests, detects or fills in a time: only the playhead and the
 person's own steps set one. The guidelines the moderators apply
 (https://wiki.sponsor.ajay.app/w/Guidelines) are summarised in the editor,
 and the server's own refusals are shown as it words them.

 The frames come from the flat Metal player (`frameImageCommand`); with
 anything else playing (WebKit) the editor says so and cannot submit.
 tvOS has no editor: timing a cut with a Siri Remote is a poor fit.
 */

#if HYPNOS_YOUTUBE && !os(tvOS)

import SwiftUI

struct SponsorBlockSubmitSheet: View {
    @Bindable var windowModel: VideoWindowModel
    @Environment(\.dismiss) private var dismiss

    private enum End { case start, end }
    private enum Stage { case edit, review }

    @State private var stage: Stage = .edit
    @State private var category: SponsorBlockCategory = .sponsor
    @State private var start: Double?
    @State private var end: Double?
    @State private var startImage: CGImage?
    @State private var endImage: CGImage?
    @State private var loading: Set<Int> = []
    @State private var previewed = false
    @State private var previewTask: Task<Void, Never>?
    @State private var sending = false
    @State private var sent = false
    @State private var message: String?

    private var canReadFrames: Bool { windowModel.frameImageCommand != nil }
    private var duration: Double { windowModel.duration }

    private var draft: SponsorBlockDraft? {
        guard let start, let end else { return nil }
        let value = SponsorBlockDraft(category: category, start: start, end: end)
        return value.isValid ? value : nil
    }

    /// What should stop a send, then what is only worth a second look.
    private var blockers: [String] {
        guard let start, let end else { return [] }
        var list: [String] = []
        if end <= start { list.append("The end has to come after the start.") }
        else if end - start < 0.5 { list.append("A segment shorter than half a second isn't worth a skip.") }
        if duration > 0, end - start > duration * 0.95 {
            list.append("This covers nearly the whole video. Use a full-video label on SponsorBlock's site instead.")
        }
        return list
    }

    private var cautions: [String] {
        guard let start, let end, end > start else { return [] }
        var list: [String] = []
        if windowModel.segmentSkipper.segments.contains(where: { $0.startSeconds < end && $0.endSeconds > start }) {
            list.append("Part of this is already marked. Don't extend a bad segment: send one covering the whole section.")
        }
        return list
    }

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .edit: editor
                case .review: review
                }
            }
            .navigationTitle(stage == .edit ? "Submit a Segment" : "Review Before Sending")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(sent ? "Done" : "Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 640)
        #endif
        .onAppear {
            windowModel.pauseCommand?()
            if start == nil, let a = windowModel.loopController.pointA { setTime(a, for: .start) }
            if end == nil, let b = windowModel.loopController.pointB { setTime(b, for: .end) }
        }
        .onDisappear { previewTask?.cancel() }
    }

    // MARK: Edit

    private var editor: some View {
        Form {
            if !canReadFrames {
                Section {
                    Label("Frames need the native player. Reopen the video with it to send a segment.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Picker("Category", selection: $category) {
                    ForEach(SponsorBlockCategory.allCases) { Text($0.displayName).tag($0) }
                }
            } footer: {
                Text("Mark only what is the category: start just before it, end on the first frame after. Not a whole video, and nothing already marked.")
            }

            endSection("Start", which: .start, time: start, image: startImage)
            endSection("End", which: .end, time: end, image: endImage)

            Section {
                Button { preview() } label: {
                    Label(previewTask == nil ? "Preview the Cut" : "Stop Preview",
                          systemImage: previewTask == nil ? "play.rectangle" : "stop.circle")
                }
                .disabled(draft == nil || !blockers.isEmpty)
                ForEach(blockers, id: \.self) { Text($0).foregroundStyle(.red) }
                ForEach(cautions, id: \.self) { Text($0).foregroundStyle(.orange) }
            } footer: {
                Text("Plays three seconds before the start, jumps to the end and plays three more: what a viewer would see. Needed once before you can review.")
            }

            Section {
                Button("Review…") { stage = .review }
                    .disabled(draft == nil || !blockers.isEmpty || startImage == nil || endImage == nil || !previewed)
            } footer: {
                if !previewed, draft != nil {
                    Text("Preview the cut first.")
                }
            }
        }
    }

    private func endSection(_ title: String, which: End, time: Double?, image: CGImage?) -> some View {
        Section(title) {
            frameView(image, loading: loading.contains(which == .start ? 0 : 1))
            HStack {
                Text(time.map(Self.format) ?? "Not set").monospacedDigit().font(.title3)
                Spacer()
                Button(time == nil ? "Mark \(title) at Playhead" : "Re-mark at Playhead") {
                    setTime(windowModel.currentTime, for: which)
                }
            }
            if let time {
                HStack(spacing: 6) {
                    ForEach([-1.0, -0.1, -0.02, 0.02, 0.1, 1.0], id: \.self) { step in
                        Button(Self.stepTitle(step)) { setTime(time + step, for: which) }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
        }
    }

    private func frameView(_ image: CGImage?, loading: Bool) -> some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.85))
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else if !loading {
                Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
            }
            if loading { ProgressView() }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Review

    private var review: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    VStack { frameView(startImage, loading: false); Text("Start \(start.map(Self.format) ?? "")").monospacedDigit() }
                    VStack { frameView(endImage, loading: false); Text("End \(end.map(Self.format) ?? "")").monospacedDigit() }
                }
                LabeledContent("Category", value: category.displayName)
                if let start, let end {
                    LabeledContent("Length", value: String(format: "%.1f s", end - start))
                }
            }
            ForEach(cautions, id: \.self) { caution in Section { Text(caution).foregroundStyle(.orange) } }

            Section {
                Button {
                    send()
                } label: {
                    HStack {
                        Text(sent ? "Sent" : "Submit to SponsorBlock").fontWeight(.semibold)
                        if sending { Spacer(); ProgressView() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(sending || sent || draft == nil)
                Button("Back to Editing") { stage = .edit }.disabled(sending)
            } footer: {
                if let message {
                    Text(message).foregroundStyle(sent ? Color.secondary : Color.red)
                } else {
                    Text("Public and permanent: sent to \(SponsorBlock.serverURL.host() ?? "the server") with the video and a private id this device made. You can't withdraw it afterwards.")
                }
            }
        }
    }

    // MARK: Actions

    private func setTime(_ value: Double, for which: End) {
        let clamped = min(max(value, 0), duration > 0 ? duration : .greatestFiniteMagnitude)
        previewed = false
        switch which {
        case .start: start = clamped
        case .end: end = clamped
        }
        let index = which == .start ? 0 : 1
        loading.insert(index)
        Task {
            let image = await windowModel.frameImageCommand?(clamped)
            // A later step may have moved this end on meanwhile.
            guard (which == .start ? start : end) == clamped else { return }
            if which == .start { startImage = image } else { endImage = image }
            loading.remove(index)
        }
    }

    /// Run-up, the jump over the cut, and the run-out, as a viewer sees it.
    private func preview() {
        if let task = previewTask { task.cancel(); previewTask = nil; windowModel.pauseCommand?(); return }
        guard let draft else { return }
        previewTask = Task {
            let lead = 3.0
            windowModel.endScrub(at: max(0, draft.start - lead))
            windowModel.playCommand?()
            var jumped = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
                let now = windowModel.currentTime
                if !jumped, now >= draft.start - 0.04 {
                    windowModel.endScrub(at: draft.end)
                    jumped = true
                } else if jumped, now >= draft.end + lead {
                    break
                }
            }
            windowModel.pauseCommand?()
            if jumped, !Task.isCancelled { previewed = true }
            previewTask = nil
        }
    }

    private func send() {
        guard let draft, let id = windowModel.youTubeID else { return }
        sending = true
        message = nil
        Task {
            do {
                _ = try await SponsorBlock.submit(draft, for: id, videoDuration: windowModel.duration)
                sent = true
                message = "Sent. Thank you."
            } catch {
                message = error.localizedDescription
            }
            sending = false
        }
    }

    private static func stepTitle(_ step: Double) -> String {
        let magnitude = abs(step)
        let text = magnitude >= 1 ? String(format: "%.0f s", magnitude) : String(format: "%g s", magnitude)
        return (step < 0 ? "−" : "+") + text
    }

    private static func format(_ seconds: Double) -> String {
        let whole = Int(seconds)
        return String(format: "%d:%02d.%02d", whole / 60, whole % 60, Int((seconds - Double(whole)) * 100))
    }
}

#endif
