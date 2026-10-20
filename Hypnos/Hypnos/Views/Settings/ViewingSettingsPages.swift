/*
 Hypnos - Settings: how things look and play (visionOS and iOS)

 The pages under Settings → Viewing, plus Slideshows. These used to be one
 "Display" section of nineteen rows; each page now holds one concern. None
 of them is offered on macOS or tvOS, whose own viewers don't read these
 settings.
 */

import RAVEMedia
import SwiftUI

/// A Settings page: a grouped form with a title, the shape every page shares.
struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .navigationTitle(title)
    }
}

struct GeneralSettingsPage: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        SettingsPage("General") {
            Section {
                Toggle("Reduce Motion", isOn: $appModel.reduceMotion)
                if appModel.systemReduceMotion && !appModel.reduceMotion {
                    Text("Currently enforced by system Accessibility setting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if PlatformCapabilities.supportsMultipleWindows {
                    Toggle("Always Open In New Window", isOn: $appModel.openMediaInNewWindows)
                }
                // A window with rounded glass corners is a visionOS thing; on
                // a phone the photo is content inside the screen, and
                // rounding it just crops the picture.
                if PlatformCapabilities.supportsWindowResizing {
                    Toggle("Rounded Corners", isOn: $appModel.roundedCorners)
                }
                Picker("Auto-hide Controls After", selection: $appModel.autoHideDelay) {
                    ForEach(AppModel.autoHideDelayOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }
}

struct GallerySettingsPage: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        SettingsPage("Gallery") {
            Section {
                Picker("Pictures Grid", selection: $appModel.galleryGridStyle) {
                    ForEach(GalleryGridStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.menu)

                // Diorama thumbnails pop their foreground forward in z.
                if PlatformCapabilities.supportsDiorama, !appModel.effectiveReduceMotion {
                    Picker("Thumbnail Style", selection: $appModel.thumbnailStyle) {
                        ForEach(ThumbnailStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.menu)
                    if appModel.thumbnailStyle == .depth {
                        Text(RAVEStillDepthEstimator.shared.isModelAvailable
                             ? "Shows each thumbnail in 3D using the Real-Time depth model."
                             : "Needs a depth model (Settings → AI 3D → Manage Depth Models). Diorama is used until one is installed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct PhotoSettingsPage: View {
    @Environment(AppModel.self) private var appModel
    @State private var showEnhancementsClearConfirmation = false

    var body: some View {
        @Bindable var appModel = appModel
        SettingsPage("Photos") {
            if PlatformCapabilities.supportsSpatial3D {
                Section {
                    Picker("Default Viewing Mode", selection: $appModel.defaultImageViewingMode) {
                        ForEach(DefaultImageViewingMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    if PlatformCapabilities.supportsDiorama {
                        Picker("Diorama Layer Distance", selection: $appModel.dioramaDistance) {
                            ForEach(AppModel.dioramaDistanceOptions, id: \.value) { option in
                                Text(option.label).tag(option.value)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    if PlatformCapabilities.supportsImmersiveSpaces {
                        Toggle("Fully Immersive 3D Mode", isOn: $appModel.fullyImmersive3DMode)
                    }
                }
            }

            Section {
                Toggle("Remember Image Enhancements", isOn: Binding(
                    get: { appModel.rememberImageEnhancements },
                    set: { newValue in
                        if newValue {
                            appModel.rememberImageEnhancements = true
                        } else {
                            showEnhancementsClearConfirmation = true
                        }
                    }
                ))
                if PlatformCapabilities.supportsSpatial3D, appModel.rememberImageEnhancements {
                    Toggle("Remember Last 3D State", isOn: $appModel.autoRestoreSpatial3D)
                }
            } footer: {
                Text(PlatformCapabilities.supportsSpatial3D
                     ? "Reopening a photo brings back its auto-enhance or background removal, and with Remember Last 3D State, its 3D."
                     : "Reopening a photo brings back its auto-enhance or background removal.")
            }

            Section {
                Picker("2D Resolution Limit", selection: $appModel.maxImageResolution) {
                    ForEach(AppModel.maxImageResolutionOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .pickerStyle(.menu)
                if PlatformCapabilities.supportsSpatial3D {
                    Picker("Spatial 3D Resolution Limit", selection: $appModel.spatial3DMaxResolution) {
                        ForEach(AppModel.maxImageResolutionOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .pickerStyle(.menu)
                }
            } footer: {
                Text("Photos larger than this are scaled down when opened.")
            }
        }
        .alert("Clear Saved Enhancements?", isPresented: $showEnhancementsClearConfirmation) {
            Button("Disable & Clear Data", role: .destructive) {
                appModel.rememberImageEnhancements = false
                Task { await appModel.clearImageEnhancementData() }
            }
            Button("Disable & Keep Data") {
                appModel.rememberImageEnhancements = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Would you like to clear existing remembered enhancements? Keeping the data allows them to be restored if you re-enable this setting.")
        }
    }
}

struct VideoSettingsPage: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        SettingsPage("Videos") {
            Section {
                Toggle("Mute Videos on Open", isOn: $appModel.videoAutoplayMuted)
            } footer: {
                Text("Videos always start playing automatically; turn this off to open them with sound. Applies to video windows and the gallery long-press preview.")
            }
            #if !os(tvOS)
            Section {
                Toggle("Pinch to Zoom Videos", isOn: $appModel.pinchToZoomVideos)
            }
            #endif
        }
    }
}

struct SlideshowSettingsPage: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        SettingsPage("Slideshows") {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Delay")
                        Spacer()
                        Text(Self.formatDelay(appModel.slideshowDelay))
                            .foregroundStyle(.secondary)
                    }
                    #if !os(tvOS)
                    Slider(value: $appModel.slideshowDelay, in: 3...120, step: 1)
                    #endif
                }
                Toggle("Show Clock", isOn: $appModel.slideshowShowClock)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Text Size")
                        Spacer()
                        Text(String(format: "%.0f%%", appModel.slideshowTextSize * 100))
                            .foregroundStyle(.secondary)
                    }
                    #if !os(tvOS)
                    Slider(value: $appModel.slideshowTextSize, in: 0.5...3.0, step: 0.1)
                    #endif
                }
                Toggle("Fit to Window Aspect Ratio", isOn: $appModel.slideshowUseAspectRatio)
                Toggle("Ken Burns Effect", isOn: $appModel.slideshowEnableKenBurns)
                Toggle("Dynamic Brightness", isOn: $appModel.slideshowEnableDynamicBrightness)
                if PlatformCapabilities.supportsDiorama {
                    Toggle("Diorama Layers", isOn: $appModel.slideshowEnableDiorama)
                }
                Toggle("Transparent Background", isOn: $appModel.slideshowTransparentBackground)
                Picker("2D Resolution Limit", selection: $appModel.slideshowMaxImageResolution2D) {
                    ForEach(AppModel.maxImageResolutionOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .pickerStyle(.menu)
                if PlatformCapabilities.supportsSpatial3D {
                    Picker("3D Resolution Limit", selection: $appModel.slideshowMaxImageResolution3D) {
                        ForEach(AppModel.maxImageResolutionOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .pickerStyle(.menu)
                }
            } footer: {
                Text("Used for the first picture slideshow and the first video slideshow; after that, each remembers the changes made in its window.")
            }
        }
    }

    private static func formatDelay(_ seconds: TimeInterval) -> String {
        let intSeconds = Int(seconds)
        guard intSeconds >= 60 else { return "\(intSeconds) seconds" }
        let minutes = intSeconds / 60
        let remainingSeconds = intSeconds % 60
        return remainingSeconds == 0 ? "\(minutes) min" : "\(minutes) min \(remainingSeconds) sec"
    }
}
