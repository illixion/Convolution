/*
 Hypnos - Visual Adjustments Popover

 Two-tab popover for adjusting brightness, contrast, and saturation.
 "Current" tab stores per-image/video settings, "Global" tab sets
 defaults applied when no per-item settings exist. Both tabs include
 a Reset button. Photos also get an auto-enhance toggle.
 */

import RAVEMedia
import SwiftUI

struct VisualAdjustmentsPopover: View {
    enum Tab: String, CaseIterable {
        case current = "Current"
        case global = "Global"
        case viewer = "Viewer"
    }

    @State private var selectedTab: Tab = .current

    /// Current per-item adjustments (photo or video)
    @Binding var currentAdjustments: VisualAdjustments

    /// Global default adjustments
    @Binding var globalAdjustments: VisualAdjustments

    /// Whether auto-enhance is available (true for photos, false for videos/GIFs)
    let showAutoEnhance: Bool

    /// Whether the per-image Sharpen slider is meaningful. RealityKit's
    /// ImagePresentationComponent ignores compositing-time sharpening on
    /// visionOS, so showing the slider while a 3D image is on screen is
    /// just misleading. The global Sharpen control on the Default tab
    /// stays available — it still affects 2D windows elsewhere.
    var showSharpen: Bool = true

    /// When set (spatial-3D photo), shows a "Distance" slider bound to it. The
    /// caller supplies the mode-appropriate value (windowed vs immersive) so the
    /// two are persisted separately.
    var scale3D: Binding<Double>? = nil

    /// Whether auto-enhance is currently processing
    var isProcessingAutoEnhance: Bool = false

    /// Callback for auto-enhance toggle
    var onToggleAutoEnhance: (() -> Void)? = nil

    /// Callback when current adjustments change (for persistence)
    var onCurrentAdjustmentsChanged: ((VisualAdjustments) -> Void)? = nil

    // MARK: - Background Removal

    /// Whether to show the background removal button
    var showBackgroundRemoval: Bool = false

    /// Current background removal state
    var backgroundRemovalState: BackgroundRemovalState = .original

    /// Callback for background removal toggle
    var onToggleBackgroundRemoval: (() -> Void)? = nil

    // MARK: - AI HDR

    /// Whether to show the AI HDR button (SDR photos given a generated gain map)
    var showAIHDR: Bool = false

    var isAIHDREnabled: Bool = false

    var isProcessingAIHDR: Bool = false

    var onToggleAIHDR: (() -> Void)? = nil

    // MARK: - Flip Image

    /// Whether to show the flip button
    var showFlip: Bool = false

    /// Whether the image is currently flipped
    var isImageFlipped: Bool = false

    /// Callback for flip toggle
    var onToggleFlip: (() -> Void)? = nil

    // MARK: - Fake-3D Stereo

    /// When set (fake-3D video), shows Stereo Separation / Convergence sliders on
    /// the Current tab (per-window override).
    var pseudo3DSettings: Binding<Pseudo3DSettings>? = nil

    /// When set (fake-3D video), shows the same sliders on the Global tab as the
    /// default applied to fake-3D videos that haven't been individually adjusted.
    var globalPseudo3DSettings: Binding<Pseudo3DSettings>? = nil

    // MARK: - Remote Viewer Display Toggles

    /// Optional remote viewer model — when provided, shows a "Viewer" tab
    var remoteViewerModel: RemoteViewerModel? = nil

    private var visibleTabs: [Tab] {
        if remoteViewerModel != nil {
            return Tab.allCases
        }
        return [.current, .global]
    }

    var body: some View {
        VStack(spacing: 16) {
            Picker("", selection: $selectedTab) {
                ForEach(visibleTabs, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            switch selectedTab {
            case .current:
                currentTabContent
            case .global:
                globalTabContent
            case .viewer:
                viewerTabContent
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    // MARK: - Current Tab

    @ViewBuilder
    private var currentTabContent: some View {
        VStack(spacing: 14) {
            // Action buttons row (auto-enhance, background removal, AI HDR, flip)
            if showAutoEnhance || showBackgroundRemoval || showAIHDR || showFlip {
                HStack(spacing: 0) {
                    if showAutoEnhance {
                        actionToggle(
                            icon: "wand.and.stars",
                            tooltip: "Auto Enhance",
                            isActive: currentAdjustments.isAutoEnhanced,
                            isProcessing: isProcessingAutoEnhance
                        ) {
                            onToggleAutoEnhance?()
                        }
                    }

                    if showBackgroundRemoval {
                        actionToggle(
                            icon: backgroundRemovalState == .original
                                ? "person.and.background.striped.horizontal"
                                : "person.and.background.dotted",
                            tooltip: backgroundRemovalState == .original
                                ? "Remove Background"
                                : backgroundRemovalState == .removing ? "Removing…" : "Restore Background",
                            isActive: backgroundRemovalState == .removed,
                            isProcessing: backgroundRemovalState == .removing
                        ) {
                            onToggleBackgroundRemoval?()
                        }
                    }

                    if showAIHDR {
                        actionToggle(
                            icon: "sun.max",
                            tooltip: "AI HDR",
                            isActive: isAIHDREnabled,
                            isProcessing: isProcessingAIHDR
                        ) {
                            onToggleAIHDR?()
                        }
                    }

                    if showFlip {
                        actionToggle(
                            icon: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                            tooltip: "Flip Image",
                            isActive: isImageFlipped,
                            isProcessing: false
                        ) {
                            onToggleFlip?()
                        }
                    }
                }
                .background(Color.secondary.opacity(0.1), in: .capsule)

                Divider()
            }

            adjustmentSlider(
                label: "Brightness",
                value: $currentAdjustments.brightness,
                range: -0.5...0.5,
                defaultValue: 0.0
            )

            adjustmentSlider(
                label: "Contrast",
                value: $currentAdjustments.contrast,
                range: 0.2...5.0,
                defaultValue: 1.0
            )

            adjustmentSlider(
                label: "Saturation",
                value: $currentAdjustments.saturation,
                range: 0.0...5.0,
                defaultValue: 1.0
            )

            if showSharpen {
                adjustmentSlider(
                    label: "Sharpen",
                    value: $currentAdjustments.sharpen,
                    range: 0.0...1.0,
                    defaultValue: 0.0,
                    linear: true
                )
            }

            adjustmentSlider(
                label: "Opacity",
                value: $currentAdjustments.opacity,
                range: 0.01...1.0,
                defaultValue: 1.0,
                linear: true
            )

            if let scale3D {
                adjustmentSlider(
                    label: "Distance",
                    value: scale3D,
                    range: 1.0...4.0,
                    defaultValue: 1.0,
                    linear: true
                )
            }

            if let pseudo3DSettings {
                Divider()
                // (No Stereo Separation control: strength is fixed at the
                // Subtle level — see Pseudo3DSettings.depthStrength. No Auto
                // Convergence either: it tracked the pre-processed median, which
                // a fixed convergence against the per-frame-normalized map
                // already does more stably.)
                adjustmentSlider(
                    label: "Convergence",
                    value: pseudo3DSettings.convergence,
                    range: 0.0...1.0,
                    defaultValue: Pseudo3DSettings.default.convergence,
                    linear: true
                )
            }

            Button("Reset") {
                currentAdjustments.brightness = 0.0
                currentAdjustments.contrast = 1.0
                currentAdjustments.saturation = 1.0
                currentAdjustments.sharpen = 0.0
                currentAdjustments.opacity = 1.0
                currentAdjustments.scale = 1.0
                currentAdjustments.immersiveScale = 1.0
                pseudo3DSettings?.wrappedValue = .default
                // Note: auto-enhance is toggled separately, not reset here
                onCurrentAdjustmentsChanged?(currentAdjustments)
            }
            .buttonStyle(.bordered)
            .disabled(
                currentAdjustments.brightness == 0.0
                && currentAdjustments.contrast == 1.0
                && currentAdjustments.saturation == 1.0
                && currentAdjustments.sharpen == 0.0
                && currentAdjustments.opacity == 1.0
                && currentAdjustments.scale == 1.0
                && currentAdjustments.immersiveScale == 1.0
                && !(pseudo3DSettings?.wrappedValue.isModified ?? false)
            )
        }
        .onChange(of: currentAdjustments) { _, newValue in
            onCurrentAdjustmentsChanged?(newValue)
        }
    }

    // MARK: - Global Tab

    @ViewBuilder
    private var globalTabContent: some View {
        VStack(spacing: 14) {
            Text("Default adjustments applied when no per-image settings are set.")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            adjustmentSlider(
                label: "Brightness",
                value: $globalAdjustments.brightness,
                range: -0.5...0.5,
                defaultValue: 0.0
            )

            adjustmentSlider(
                label: "Contrast",
                value: $globalAdjustments.contrast,
                range: 0.3...3.0,
                defaultValue: 1.0
            )

            adjustmentSlider(
                label: "Saturation",
                value: $globalAdjustments.saturation,
                range: 0.0...3.0,
                defaultValue: 1.0
            )

            adjustmentSlider(
                label: "Sharpen",
                value: $globalAdjustments.sharpen,
                range: 0.0...1.0,
                defaultValue: 0.0,
                linear: true
            )

            adjustmentSlider(
                label: "Opacity",
                value: $globalAdjustments.opacity,
                range: 0.01...1.0,
                defaultValue: 1.0,
                linear: true
            )

            if let globalPseudo3DSettings {
                Divider()
                Text("Fake-3D default")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                adjustmentSlider(
                    label: "Convergence",
                    value: globalPseudo3DSettings.convergence,
                    range: 0.0...1.0,
                    defaultValue: Pseudo3DSettings.default.convergence,
                    linear: true
                )
            }

            Button("Reset") {
                globalAdjustments.reset()
                globalPseudo3DSettings?.wrappedValue = .default
            }
            .buttonStyle(.bordered)
            .disabled(!globalAdjustments.isModified && !(globalPseudo3DSettings?.wrappedValue.isModified ?? false))
        }
    }

    // MARK: - Viewer Tab (Remote Viewer only)

    @ViewBuilder
    private var viewerTabContent: some View {
        if let model = remoteViewerModel {
            @Bindable var model = model
            VStack(spacing: 14) {
                Text("Display toggles for this viewer session.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Toggle("Show Clock", isOn: $model.displayShowClock)

                Toggle("Ken Burns Effect", isOn: $model.displayEnableKenBurns)

                Toggle("Diorama (Foreground Pop-Out)", isOn: $model.displayEnableDiorama)

                Toggle("Dynamic Brightness", isOn: $model.displayEnableDynamicBrightness)

                Toggle("Transparent Background", isOn: $model.displayTransparentBackground)

                Toggle("Fit to Aspect Ratio", isOn: $model.displayUseAspectRatio)

                Divider()

                VStack(spacing: 4) {
                    HStack {
                        Text("Slideshow Interval")
                            .font(.subheadline)
                        Spacer()
                        Text(formatDelay(model.displayDelay))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                    #if !os(tvOS)
                    Slider(
                        value: $model.displayDelay,
                        in: 3...120,
                        step: 1
                    )
                    #endif
                }
            }
        }
    }

    // MARK: - Action Toggle

    @ViewBuilder
    private func actionToggle(
        icon: String,
        tooltip: String,
        isActive: Bool,
        isProcessing: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if isProcessing {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: icon)
                        .fontWeight(isActive ? .semibold : .regular)
                }
            }
            .font(.title3)
            .frame(width: 44, height: 44)
            .background(isActive ? Color.accentColor.opacity(0.2) : .clear, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.borderless)
        .disabled(isProcessing)
        .help(tooltip)
    }

    // MARK: - Slider Component

    /// Exponent for non-linear slider curve. Higher values give more precision
    /// near the default and faster acceleration toward the extremes.
    private static let curveExponent: Double = 2.0

    @ViewBuilder
    private func adjustmentSlider(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        defaultValue: Double,
        linear: Bool = false
    ) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                    .font(.subheadline)
                Spacer()
                Text(formatValue(value.wrappedValue, defaultValue: defaultValue))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(value.wrappedValue != defaultValue ? .accentColor : .secondary)
            }
            // This whole popover isn't part of the tvOS root UI (TV's photo/
            // video adjustments, where they exist at all, avoid free-form
            // sliders by design — see Hypnos/CLAUDE.md "tvOS") — kept
            // compiling only, not reachable.
            #if !os(tvOS)
            if linear {
                Slider(value: value, in: range)
            } else {
                Slider(
                    value: nonLinearBinding(value: value, range: range, defaultValue: defaultValue),
                    in: 0...1
                )
            }
            #endif
        }
    }

    /// Creates a binding that maps between a normalized 0...1 slider position and the
    /// actual value using a power curve. The default value always sits at slider center (0.5),
    /// giving high precision for small adjustments and accelerating toward the extremes.
    private func nonLinearBinding(
        value: Binding<Double>,
        range: ClosedRange<Double>,
        defaultValue: Double
    ) -> Binding<Double> {
        let exponent = Self.curveExponent
        let lower = range.lowerBound
        let upper = range.upperBound

        return Binding<Double>(
            get: {
                let v = value.wrappedValue
                if v <= defaultValue {
                    let fraction = defaultValue > lower
                        ? (defaultValue - v) / (defaultValue - lower)
                        : 0
                    return 0.5 - pow(fraction, 1.0 / exponent) * 0.5
                } else {
                    let fraction = upper > defaultValue
                        ? (v - defaultValue) / (upper - defaultValue)
                        : 0
                    return 0.5 + pow(fraction, 1.0 / exponent) * 0.5
                }
            },
            set: { t in
                if t <= 0.5 {
                    let halfT = (0.5 - t) / 0.5
                    value.wrappedValue = defaultValue - pow(halfT, exponent) * (defaultValue - lower)
                } else {
                    let halfT = (t - 0.5) / 0.5
                    value.wrappedValue = defaultValue + pow(halfT, exponent) * (upper - defaultValue)
                }
            }
        )
    }

    /// Format slideshow delay as human-readable string
    private func formatDelay(_ seconds: TimeInterval) -> String {
        if seconds >= 60 {
            let mins = Int(seconds) / 60
            let secs = Int(seconds) % 60
            return secs > 0 ? "\(mins)m \(secs)s" : "\(mins)m"
        }
        return "\(Int(seconds))s"
    }

    /// Format a slider value for display, showing "+/-" prefix for brightness-style values.
    /// Uses 3 decimal places to reflect the non-linear slider's higher precision near center.
    private func formatValue(_ value: Double, defaultValue: Double) -> String {
        if defaultValue == 0.0 {
            // Brightness-style: show +/- prefix
            if value >= 0 {
                return String(format: "+%.3f", value)
            } else {
                return String(format: "%.3f", value)
            }
        } else {
            // Contrast/saturation-style: show as multiplier
            return String(format: "%.3f", value)
        }
    }
}
