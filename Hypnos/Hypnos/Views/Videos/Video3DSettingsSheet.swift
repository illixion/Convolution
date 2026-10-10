/*
 Hypnos - Video 3D Settings Sheet

 SwiftUI sheet for selecting 3D conversion settings for a video.
 */

import SwiftUI
import VergenceApple

struct Video3DSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Current settings (if editing existing)
    let initialSettings: Video3DSettings?

    /// Callback when settings are applied
    let onApply: (Video3DSettings) -> Void

    /// Callback when cancelled
    let onCancel: (() -> Void)?

    @State private var selectedFormat: StereoscopicFormat
    @State private var eyesReversed: Bool
    @State private var fieldOfView: Float
    @State private var disparityAdjustment: Float

    init(
        initialSettings: Video3DSettings? = nil,
        onApply: @escaping (Video3DSettings) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        self.initialSettings = initialSettings
        self.onApply = onApply
        self.onCancel = onCancel

        // Initialize state from initial settings or defaults
        let settings = initialSettings ?? Video3DSettings.defaults(for: .sideBySide)
        _selectedFormat = State(initialValue: settings.format)
        _eyesReversed = State(initialValue: settings.eyesReversed)
        _fieldOfView = State(initialValue: settings.horizontalFieldOfView)
        _disparityAdjustment = State(initialValue: settings.horizontalDisparityAdjustment)
    }

    var body: some View {
        NavigationStack {
            Form {
                formatSection
                eyesSection
                advancedSection
            }
            .navigationTitle("3D Video Settings")
            #if !os(tvOS) && !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel?()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        let settings = Video3DSettings(
                            format: selectedFormat,
                            eyesReversed: eyesReversed,
                            horizontalFieldOfView: fieldOfView,
                            horizontalDisparityAdjustment: disparityAdjustment
                        )
                        onApply(settings)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 500)
    }

    // MARK: - Sections

    private var formatSection: some View {
        Section {
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                ForEach(StereoscopicFormat.allCases, id: \.self) { format in
                    FormatButton(
                        format: format,
                        isSelected: selectedFormat == format
                    ) {
                        selectedFormat = format
                    }
                }
            }
            .padding(.vertical, 8)
        } header: {
            Text("Format")
        } footer: {
            Text(formatDescription)
                .foregroundStyle(.secondary)
        }
    }

    private var formatDescription: String {
        switch selectedFormat {
        case .sideBySide:
            return "Left and right eye views placed side by side at full width."
        case .halfSideBySide:
            return "Left and right eye views squeezed horizontally to fit side by side."
        case .overUnder:
            return "Left eye view on top, right eye view on bottom at full height."
        case .halfOverUnder:
            return "Left eye view on top, right eye view on bottom, squeezed vertically."
        }
    }

    private var eyesSection: some View {
        Section {
            Toggle("Swap Left/Right Eyes", isOn: $eyesReversed)
        } footer: {
            Text("Enable if the 3D effect appears inverted (objects that should be in front appear behind).")
                .foregroundStyle(.secondary)
        }
    }

    private var advancedSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Field of View")
                    Spacer()
                    Text("\(Int(fieldOfView))°")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                #if !os(tvOS)
                Slider(value: $fieldOfView, in: 60...120, step: 5)
                #endif
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Depth Adjustment")
                    Spacer()
                    Text("\(Int(disparityAdjustment))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                #if !os(tvOS)
                Slider(value: $disparityAdjustment, in: 0...400, step: 10)
                #endif
            }
        } header: {
            Text("Advanced")
        } footer: {
            Text("Higher depth values increase the 3D effect. Field of view affects how the content fills your view.")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Format Button

private struct FormatButton: View {
    let format: StereoscopicFormat
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                formatIcon
                    .font(.system(size: 24))
                    .frame(height: 32)

                Text(format.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(format.shortLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var formatIcon: some View {
        switch format {
        case .sideBySide, .halfSideBySide:
            HStack(spacing: 2) {
                Rectangle()
                    .fill(Color.blue.opacity(0.7))
                    .frame(width: 18, height: 24)
                Rectangle()
                    .fill(Color.red.opacity(0.7))
                    .frame(width: 18, height: 24)
            }
        case .overUnder, .halfOverUnder:
            VStack(spacing: 2) {
                Rectangle()
                    .fill(Color.blue.opacity(0.7))
                    .frame(width: 32, height: 12)
                Rectangle()
                    .fill(Color.red.opacity(0.7))
                    .frame(width: 32, height: 12)
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct Video3DSettingsSheet_Previews: PreviewProvider {
    static var previews: some View {
        Video3DSettingsSheet(
            initialSettings: nil,
            onApply: { _ in }
        )
    }
}
#endif
