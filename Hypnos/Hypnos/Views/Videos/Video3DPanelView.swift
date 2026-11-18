/*
 Hypnos - the 3D panel

 A window of its own beside a video window (like Adjustments), so the video
 stays in view while it is edited: what the video was found to be and why
 (`VideoWindowModel.detectedFormat`, the picture analysis), a frame of it
 with each eye's part marked (L and R, and a fisheye lens's circle), and
 the controls. Every change shows at once, in the preview and in the video
 itself: the window's live 3D takes a new layout on the next frame, and the
 VR sphere its new format. "Use Detected" puts the automatic answer back.
 visionOS only: nowhere else plays 3D.
 */

#if os(visionOS)
import SwiftUI
import VergenceApple

struct Video3DPanelView: View {
    @Environment(AppModel.self) private var appModel
    @DismissWindowProxy private var dismissWindow

    var body: some View {
        Group {
            if let target = appModel.video3DPanelTarget {
                Video3DPanelContent(windowModel: target)
                    .navigationTitle(target.videoDisplayName)
            } else {
                // Its video window closed.
                Color.clear.onAppear { dismissWindow() }
            }
        }
        .onDisappear { appModel.video3DPanelTarget = nil }
    }
}

private struct Video3DPanelContent: View {
    @Bindable var windowModel: VideoWindowModel
    @AppStorage(VROpening.key, store: HypnosDefaults.store) private var opensVR = true

    /// What the video is shown as.
    enum Kind: String, CaseIterable, Identifiable {
        case flat, stereo, vr
        var id: String { rawValue }
        var title: String {
            switch self {
            case .flat: "2D"
            case .stereo: "3D"
            case .vr: "VR"
            }
        }
    }

    enum Projection: String, CaseIterable, Identifiable {
        case vr180, vr360, fisheye
        var id: String { rawValue }
        var title: String {
            switch self {
            case .vr180: "180°"
            case .vr360: "360°"
            case .fisheye: "Fisheye"
            }
        }
    }

    enum Packing: String, CaseIterable, Identifiable {
        case sideBySide, overUnder, mono
        var id: String { rawValue }
        var title: String {
            switch self {
            case .sideBySide: "Side by Side"
            case .overUnder: "Over-Under"
            case .mono: "One Picture"
            }
        }
    }

    private var format: VRFormat { windowModel.videoFormat }

    private var kind: Kind {
        if format.projection.isImmersive { return .vr }
        return format.layout == nil ? .flat : .stereo
    }

    var body: some View {
        Form {
            Section {
                Video3DPreview(image: windowModel.formatPreview, format: format)
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            } footer: {
                Text(previewCaption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Show As", selection: Binding(get: { kind }, set: setKind)) {
                    ForEach(Kind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                switch kind {
                case .flat: EmptyView()
                case .stereo: stereoControls
                case .vr: vrControls
                }
            } header: {
                Text("Show As")
            }

            detectedSection

            if kind == .vr || windowModel.isVRVideo {
                Section {
                    if windowModel.isVRVideo {
                        Button(windowModel.wantsVR ? "Leave VR" : "View Around Me") {
                            windowModel.wantsVR.toggle()
                        }
                        // The likely readings as big buttons under the video,
                        // to flip between while looking around.
                        Button("Compare Guesses") {
                            windowModel.wantsVR = true
                            windowModel.startFormatCompare()
                        }
                        .disabled(windowModel.formatCompare != nil)
                    }
                    Toggle("Open VR Videos Around Me", isOn: $opensVR)
                } footer: {
                    Text("A VR video plays on a sphere around you; its window keeps the controls.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 360, idealWidth: 400, minHeight: 520)
        .onAppear { windowModel.refreshFormatPreview() }
    }

    // MARK: - Controls

    @ViewBuilder
    private var stereoControls: some View {
        let layout = format.layout ?? PackedStereoLayout(arrangement: .sideBySide, isHalfResolution: false)
        Picker("Packing", selection: Binding(get: { layout.arrangement }, set: { arrangement in
            var changed = layout
            changed.arrangement = arrangement
            choose(VRFormat(layout: changed, projection: .flat))
        })) {
            Text("Side by Side").tag(PackedStereoLayout.Arrangement.sideBySide)
            Text("Over-Under").tag(PackedStereoLayout.Arrangement.overUnder)
        }
        .pickerStyle(.segmented)
        Toggle("Half Resolution", isOn: Binding(get: { layout.isHalfResolution }, set: { half in
            var changed = layout
            changed.isHalfResolution = half
            choose(VRFormat(layout: changed, projection: .flat))
        }))
        swapToggle
    }

    @ViewBuilder
    private var vrControls: some View {
        Picker("Projection", selection: Binding(get: { projection }, set: setProjection)) {
            ForEach(Projection.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        if case .fisheye(let fieldOfView, let ellipse) = format.projection {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Lens Field of View")
                    Spacer()
                    Text("\(Int(fieldOfView.rounded()))°").foregroundStyle(.secondary).monospacedDigit()
                }
                #if !os(tvOS)
                Slider(value: Binding(get: { fieldOfView }, set: { value in
                    var changed = format
                    changed.projection = .fisheye(fieldOfView: value, ellipse: ellipse)
                    choose(changed)
                }), in: 160 ... 240, step: 5)
                #endif
            }
        }
        Picker("Packing", selection: Binding(get: { packing }, set: setPacking)) {
            ForEach(Packing.allCases) { Text($0.title).tag($0) }
        }
        if format.layout != nil { swapToggle }
    }

    private var swapToggle: some View {
        Toggle("Swap Eyes", isOn: Binding(get: { format.layout?.eyesReversed ?? false }, set: { swapped in
            var changed = format
            changed.layout?.eyesReversed = swapped
            choose(changed)
        }))
    }

    @ViewBuilder
    private var detectedSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(windowModel.detectedFormat.summary.capitalizedFirst)
                    Text(detectionSource).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if windowModel.vrOverride == nil {
                    Text("In Use").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Use Detected") { choose(nil) }
                }
            }
            if let analysis = windowModel.formatAnalysis, !analysis.reasons.isEmpty {
                DisclosureGroup("Why") {
                    ForEach(Array(analysis.reasons.enumerated()), id: \.offset) { _, reason in
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Detected")
        }
    }

    private var detectionSource: String {
        guard let analysis = windowModel.formatAnalysis else {
            return windowModel.nativePlayerGeneration == 0
                ? "From the file's name and tags (the picture is looked at once it plays here)"
                : "From the file's name and tags; looking at the picture…"
        }
        let sure = Int((analysis.confidence * 100).rounded())
        if analysis.confidence < VideoWindowModel.formatConfidence {
            return "The picture wasn't clear enough (\(sure)% sure): going by the file's name and tags"
        }
        return "From the picture and the file, \(sure)% sure"
    }

    private var previewCaption: String {
        if windowModel.formatPreview == nil { return "A frame of the video shows here once it plays." }
        switch kind {
        case .flat: return "Shown as it is, one picture."
        case .stereo, .vr:
            if format.layout == nil { return "One picture, seen by both eyes." }
            return "L is what your left eye sees, R your right. If near things look far, swap the eyes."
        }
    }

    // MARK: - Choosing

    private var projection: Projection {
        switch format.projection {
        case .equirectangular(let degrees): degrees > 270 ? .vr360 : .vr180
        case .fisheye: .fisheye
        case .flat: .vr180
        }
    }

    private var packing: Packing {
        guard let layout = format.layout else { return .mono }
        return layout.arrangement == .sideBySide ? .sideBySide : .overUnder
    }

    private func setKind(_ kind: Kind) {
        let layout = format.layout ?? windowModel.detectedFormat.layout
            ?? PackedStereoLayout(arrangement: .sideBySide, isHalfResolution: false)
        switch kind {
        case .flat:
            choose(VRFormat(layout: nil, projection: .flat))
        case .stereo:
            var flat = layout
            if format.projection.isImmersive { flat.isHalfResolution = false }
            choose(VRFormat(layout: flat, projection: .flat))
        case .vr:
            let detected = windowModel.detectedFormat
            let projection = detected.projection.isImmersive ? detected.projection : .vr180
            var vrLayout = layout
            vrLayout.isHalfResolution = false
            choose(VRFormat(layout: vrLayout, projection: projection))
        }
    }

    private func setProjection(_ choice: Projection) {
        var changed = format
        switch choice {
        case .vr180: changed.projection = .vr180
        case .vr360: changed.projection = .vr360
        case .fisheye:
            let detected = windowModel.detectedFormat.projection
            if case .fisheye = detected { changed.projection = detected } else { changed.projection = .fisheye(190) }
        }
        choose(changed)
    }

    private func setPacking(_ choice: Packing) {
        var changed = format
        switch choice {
        case .mono: changed.layout = nil
        case .sideBySide, .overUnder:
            var layout = format.layout ?? PackedStereoLayout(arrangement: .sideBySide, isHalfResolution: false)
            layout.arrangement = choice == .sideBySide ? .sideBySide : .overUnder
            changed.layout = layout
        }
        choose(changed)
    }

    /// nil: back to what was detected. A choice equal to it is kept as
    /// automatic too, so a better analysis later still applies.
    private func choose(_ format: VRFormat?) {
        windowModel.chooseFormat(format == windowModel.detectedFormat ? nil : format)
    }
}

/// A frame of the video with each eye's part outlined and labelled, and a
/// fisheye lens's circle drawn in each eye.
struct Video3DPreview: View {
    let image: CGImage?
    let format: VRFormat

    var body: some View {
        if let image {
            let aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(aspect, contentMode: .fit)
                .overlay { GeometryReader { geometry in overlay(in: geometry.size) } }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .frame(maxHeight: 320)
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary)
                .frame(height: 160)
                .overlay { ProgressView() }
        }
    }

    @ViewBuilder
    private func overlay(in size: CGSize) -> some View {
        if format.layout != nil {
            ForEach([PackedStereoLayout.Eye.left, .right], id: \.self) { eye in
                eyeMark(eye, in: size)
            }
        } else if case .fisheye(_, let ellipse) = format.projection {
            lens(ellipse, in: CGRect(origin: .zero, size: size))
        }
    }

    private func eyeMark(_ eye: PackedStereoLayout.Eye, in size: CGSize) -> some View {
        let region = format.eyeRegion(eye)
        let rect = CGRect(x: CGFloat(region.offset.x) * size.width, y: CGFloat(region.offset.y) * size.height,
                          width: CGFloat(region.scale.x) * size.width, height: CGFloat(region.scale.y) * size.height)
        let colour: Color = eye == .left ? .cyan : .orange
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(colour, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
            Text(eye == .left ? "L" : "R")
                .font(.headline.bold())
                .foregroundStyle(.black)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(colour, in: RoundedRectangle(cornerRadius: 5))
                .padding(6)
            if case .fisheye(_, let ellipse) = format.projection {
                lens(ellipse, in: CGRect(origin: .zero, size: rect.size))
            }
        }
        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        .position(x: rect.midX, y: rect.midY)
    }

    private func lens(_ ellipse: EyeEllipse, in rect: CGRect) -> some View {
        Ellipse()
            .stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .frame(width: rect.width * ellipse.radiusX * 2, height: rect.height * ellipse.radiusY * 2)
            .position(x: rect.minX + rect.width * ellipse.centerX, y: rect.minY + rect.height * ellipse.centerY)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
#endif
