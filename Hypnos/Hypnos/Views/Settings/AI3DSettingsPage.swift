/*
 Hypnos - Settings → AI 3D (visionOS)

 Everything about fake 3D in one place: which depth model each pipeline
 uses, installing and removing models (`DepthModelManagerSheet`, which used
 to sit under Developer although AI 3D can't run without it), the playback
 switches, and the pre-processed conversions on disk.
 */

import RAVEMedia
import SwiftUI

struct AI3DSettingsPage: View {
    @Environment(AppModel.self) private var appModel
    @State private var depthModels = DepthModelManager.shared
    @State private var showDepthModelManager = false

    /// For the row that opens this page.
    @MainActor static var statusLabel: String {
        DepthModelManager.shared.installedNames.isEmpty ? "No Model" : ""
    }

    var body: some View {
        @Bindable var appModel = appModel
        SettingsPage("AI 3D") {
            // Real-time inference gates every frame (keep this fast), while
            // pre-process conversion can afford a slower, higher-quality model.
            Section {
                depthModelPicker("Real-Time Model", selection: $appModel.realtimeDepthModelName)
                depthModelPicker("Pre-Process Model", selection: $appModel.preprocessDepthModelName)
                Button {
                    showDepthModelManager = true
                } label: {
                    Label("Manage Depth Models", systemImage: "shippingbox")
                }
                if let downloading = DepthModelManager.variants.first(where: { depthModels.isDownloading($0) }) {
                    HStack(spacing: 12) {
                        ProgressView(value: depthModels.progress[downloading.name] ?? 0)
                        Text("Downloading \(downloading.displayName)…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Depth Models")
            } footer: {
                Text("AI 3D needs a depth model (~19–50 MB, downloaded from Apple's Hugging Face repo). Real-Time is used for instant playback, so a fast model is best; Pre-Process converts in the background and can use a larger one. Videos already converted keep playing in 3D without a model.")
            }

            Section {
                Toggle("AI 3D for All Videos", isOn: $appModel.defaultRealtimePseudo3D)
            } footer: {
                Text("Compatible videos open already in 3D, from their pre-processed conversion when there is one, otherwise in real time.")
            }

            Section {
                Toggle("Stable Depth", isOn: $appModel.stableDepth)
            } footer: {
                Text("Real-Time 3D holds the room's depth steady when someone walks up to the camera, eases close-ups into the nearest depth instead of clipping them, and keeps depth edges on the picture's edges. Turn off to compare with the previous behavior.")
            }

            Section {
                DepthCacheSettingsView()
            } header: {
                Text("Converted Videos")
            }
        }
        .task { depthModels.importInboxIfNeeded() }
        .sheet(isPresented: $showDepthModelManager) {
            DepthModelManagerSheet()
                .environment(appModel)
        }
    }

    /// Role-model dropdown: "Automatic" (first installed) plus every installed
    /// model. A preference naming a since-deleted model is shown as missing so
    /// the picker doesn't render an empty selection.
    @ViewBuilder
    private func depthModelPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            Text("Automatic").tag("")
            ForEach(depthModels.installedNames, id: \.self) { name in
                Text(DepthModelManager.displayName(for: name)).tag(name)
            }
            if !selection.wrappedValue.isEmpty, !depthModels.installedNames.contains(selection.wrappedValue) {
                Text("\(DepthModelManager.displayName(for: selection.wrappedValue)) (missing)")
                    .tag(selection.wrappedValue)
            }
        }
        .pickerStyle(.menu)
    }
}
