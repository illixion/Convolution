/*
 Hypnos - Settings → AI Features (visionOS, iOS, macOS)

 Everything that uses a model, in one place: the defaults for AI 3D, Smooth
 Motion, AI Upscaling and AI HDR (these were scattered over Videos, Photos and
 AI 3D), Smart Activation (the rules that switch Smooth Motion and AI
 Upscaling per video), and the pages behind them: AI 3D's depth models, AI
 Captions, and Compute Assistance (an analysis server doing the heavy work).
 Each video's View Mode menu still overrides the defaults for itself.

 Not on tvOS, whose Settings (`TVSettingsView`) offers only AI Captions.
 */

#if !os(tvOS)
import RAVEMedia
import SwiftUI

struct AIFeaturesSettingsPage: View {
    @Environment(AppModel.self) private var appModel

    /// For the row that opens this page: a missing depth model is the thing
    /// worth seeing without opening it.
    @MainActor static var statusLabel: String {
        PlatformCapabilities.supportsStereoVideo ? AI3DSettingsPage.statusLabel : ""
    }

    var body: some View {
        @Bindable var appModel = appModel
        SettingsPage("AI Features") {
            #if os(visionOS) || os(iOS)
            Section {
                if PlatformCapabilities.supportsStereoVideo {
                    featureToggle("AI 3D for All Videos", isOn: $appModel.defaultRealtimePseudo3D,
                                  detail: "Compatible videos open already in 3D, from their pre-processed conversion when there is one, otherwise in real time.")
                }
                #if os(visionOS)
                featureToggle("Smooth Motion", isOn: $appModel.smoothMotion,
                              detail: "Adds an in-between frame to 24–30 fps videos, so slow pans move in smaller steps, and to 50–60 fps videos, which then play at 100–120 fps, in 2D and AI 3D. Works up to 1080p, and in 2D for non-HDR videos; cuts and seeks are never blended.")
                #endif
                featureToggle("AI Upscaling", isOn: $appModel.aiUpscaling,
                              detail: "Plays videos of 720p and below sharper, rebuilding detail up to 1080p with the device's own upscaler as each frame is shown. For non-HDR videos in 2D, not in 3D or AI 3D, and only while the window shows the video bigger than it is.")
                #if os(visionOS)
                featureToggle("AI HDR for Videos", isOn: $appModel.aiHDRVideos,
                              detail: "Gives SDR Library titles HDR highlights, from gain maps an analysis server's workers make while you watch, in 2D and AI 3D. The highlights fade in after a title starts or you skip, and the picture's average brightness is held below where the window would dim. Needs Compute Assistance with an AI HDR worker; without one, titles play as they are.")
                #endif
            } header: {
                Text("Videos")
            } footer: {
                Text("What every video starts with. Each video can change these in its View Mode menu, and Smart Activation can decide per video.")
            }
            #else
            Section {
                featureToggle("AI Upscaling", isOn: $appModel.aiUpscaling,
                              detail: "Plays videos of 720p and below sharper, rebuilding detail up to 1080p with the device's own upscaler as each frame is shown. For non-HDR videos, and only while the window shows the video bigger than it is.")
            } header: {
                Text("Videos")
            } footer: {
                Text("What every video starts with. Each video can change it in its View Mode menu, and Smart Activation can decide per video.")
            }
            #endif

            if PlatformCapabilities.supportsAIHDR {
                Section {
                    featureToggle("AI HDR", isOn: $appModel.aiHDRByDefault,
                                  detail: "Opens photos in HDR, brightening their highlights with a gain map made on this device. Turn it on or off for a single photo in its Adjustments. Not shown in RealityKit 3D.")
                } header: {
                    Text("Photos")
                }
            }

            Section {
                NavigationLink(value: SettingsTabView.Page.smartActivation) {
                    LabeledContent {
                        Text(SmartActivationSettingsPage.statusLabel(appModel))
                    } label: {
                        Label("Smart Activation", systemImage: "wand.and.stars")
                    }
                }
            } footer: {
                Text("Rules for turning \(Self.smartFeatures) on or off for each video, by its frame rate, size and the device's power. For example, boost 24–30 fps videos to 60 but leave 50–60 fps ones alone.")
            }

            Section {
                if PlatformCapabilities.supportsStereoVideo {
                    NavigationLink(value: SettingsTabView.Page.ai3D) {
                        LabeledContent {
                            Text(AI3DSettingsPage.statusLabel)
                        } label: {
                            Label("AI 3D", systemImage: "cube")
                        }
                    }
                }
                NavigationLink(value: SettingsTabView.Page.aiCaptions) {
                    Label("AI Captions", systemImage: "captions.bubble")
                }
                #if os(visionOS)
                NavigationLink(value: SettingsTabView.Page.compute) {
                    LabeledContent {
                        Text(ComputeAssistanceSettingsPage.statusLabel)
                    } label: {
                        Label("Compute Assistance", systemImage: "server.rack")
                    }
                }
                #endif
            } header: {
                Text("Models & Services")
            }
        }
    }

    private static var smartFeatures: String {
        #if os(visionOS)
        "Smooth Motion and AI Upscaling"
        #else
        "AI Upscaling"
        #endif
    }

    /// A toggle with what it does under it.
    private func featureToggle(_ title: String, isOn: Binding<Bool>, detail: String) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#if os(visionOS)
/// Settings → AI Features → Compute Assistance: the other computers that do
/// an AI feature's heavy work. Today that is a Vergence analysis server
/// (`AnalysisCoordinator`).
struct ComputeAssistanceSettingsPage: View {
    /// For the row that opens this page.
    @MainActor static var statusLabel: String {
        if let paired = AnalysisPairing.record() {
            return paired.hostName.isEmpty ? "Paired" : paired.hostName
        }
        return AnalysisCoordinator.current() == nil ? "Not Set" : "Connected"
    }

    var body: some View {
        SettingsPage("Compute Assistance") {
            Section {
                Text("Lets a computer on your network do the heavy work for AI features while a Library title plays: Smooth Motion's in-between frames, AI 3D depth from a larger model than the headset runs, and AI HDR highlights. Without one, everything runs on this device or comes from what the Jellyfin plugin prepared overnight.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            AnalysisServerSection()
        }
    }
}
#endif
#endif
