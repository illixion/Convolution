/*
 Hypnos - Settings → Developer (visionOS, iOS)

 Diagnostics and the measurement tools: the console, memory behavior, the
 GPU memory monitor, what the galleries have loaded, and the probes and
 spikes that used to sit at the top level of Settings for everyone.
 */

import SwiftUI

struct DeveloperSettingsPage: View {
    @Environment(AppModel.self) private var appModel
    @Environment(MainWindowModel.self) private var windowModel
    @OpenWindowProxy private var openWindow

    var body: some View {
        @Bindable var appModel = appModel
        SettingsPage("Developer") {
            Section {
                Toggle("Show Debug Console", isOn: Binding(
                    get: { appModel.showDebugConsole },
                    set: { newValue in
                        appModel.showDebugConsole = newValue
                        if !newValue && windowModel.selectedTab == .console {
                            windowModel.selectedTab = .settings
                        }
                    }
                ))
            } footer: {
                Text("Adds a Console tab showing app log messages in real time.")
            }

            Section {
                Toggle("Respect System Memory Alerts", isOn: $appModel.respectMemoryAlerts)
            } footer: {
                Text("When disabled, the app will not unload images or downscale windows in response to system memory pressure.")
            }

            Section {
                Toggle("Lossy Texture Compression", isOn: $appModel.useLossyTextureCompression)
            } footer: {
                Text("Reduces GPU memory per image by ~2-4x using hardware lossy compression. Slight quality reduction. New images use the updated setting; existing windows are unaffected until reloaded.")
            }

            Section {
                Button {
                    openWindow(id: "gpu-memory")
                } label: {
                    Label("Open GPU Memory Monitor", systemImage: "memorychip")
                }
                LabeledContent("Images Loaded", value: "\(appModel.galleryImages.count)")
                LabeledContent("Videos Loaded", value: "\(appModel.galleryVideos.count)")
            }

            #if HYPNOS_PRIVATE_API && !os(visionOS)
            PrivateSpatial3DiOSProbeSection()
            #endif

            // On-device numbers for the lookahead realtime fake-3D design
            // (model budget, live refinement cost, decode-ahead depth).
            if PlatformCapabilities.supportsStereoVideo {
                DepthPipelineSpikeSection()
            }

            // Films with their Atmos objects as RealityKit spatial sources.
            FilmPlayerSection()
            #if os(visionOS)
            // Can app audio be anchored to a window instead?
            SpatialAudioProbeSection()
            #endif
        }
    }
}
