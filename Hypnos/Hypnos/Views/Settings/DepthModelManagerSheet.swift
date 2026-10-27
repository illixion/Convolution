/*
 Hypnos - Depth Model Manager Sheet

 The single home for adding and removing fake-3D depth models: installed
 models (incl. custom conversions pushed via script or dropped into Documents)
 with per-row delete, plus the offered Depth Anything V2 variants with
 download progress. Which installed model each pipeline *uses* is picked in
 Settings → Display (Real-Time vs Pre-Process dropdowns) — this sheet only
 manages what's on disk.
 */

import RAVEMedia
import SwiftUI

struct DepthModelManagerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var appModel
    @State private var depthModels = DepthModelManager.shared
    @State private var modelPendingDelete: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Installed") {
                    if depthModels.installedNames.isEmpty {
                        Text("No models installed")
                            .foregroundColor(.secondary)
                    }
                    ForEach(depthModels.installedNames, id: \.self) { name in
                        installedRow(name)
                    }
                }

                let downloadable = DepthModelManager.variants.filter { !depthModels.isInstalled($0) }
                if !downloadable.isEmpty {
                    Section("Available Downloads") {
                        ForEach(downloadable) { variant in
                            downloadRow(variant)
                        }
                    }
                }

                if let error = depthModels.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                SpeakerModelSection()

                Section {
                } footer: {
                    Text("Depth model downloads come from Apple's Hugging Face repo. Custom depth models (e.g. a Base conversion from scripts/convert-depth-model.py) can be added by copying the .mlpackage into this app's Documents folder with the Files app — it's imported automatically. Which model each 3D mode uses is chosen in Display settings.")
                }
            }
            .navigationTitle("AI Models")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                depthModels.importInboxIfNeeded()
            }
            .confirmationDialog(
                "Delete \(DepthModelManager.displayName(for: modelPendingDelete ?? ""))?",
                isPresented: Binding(
                    get: { modelPendingDelete != nil },
                    set: { if !$0 { modelPendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Model", role: .destructive) {
                    if let name = modelPendingDelete {
                        delete(name)
                    }
                    modelPendingDelete = nil
                }
                Button("Cancel", role: .cancel) { modelPendingDelete = nil }
            } message: {
                Text("Videos already pre-processed keep playing in 3D — their depth is baked into the cache.")
            }
        }
    }

    @ViewBuilder
    private func installedRow(_ name: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(DepthModelManager.displayName(for: name))
                HStack(spacing: 6) {
                    Text(ByteCountFormatter.string(fromByteCount: DepthModelStore.modelSize(named: name), countStyle: .file))
                    ForEach(roleBadges(for: name), id: \.self) { badge in
                        Text(badge)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.2), in: Capsule())
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                modelPendingDelete = name
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func downloadRow(_ variant: DepthModelManager.Variant) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(variant.displayName)
                Text("\(variant.subtitle) · \(ByteCountFormatter.string(fromByteCount: variant.approxBytes, countStyle: .file))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if depthModels.isDownloading(variant) {
                ProgressView(value: depthModels.progress[variant.name] ?? 0)
                    .frame(width: 80)
            } else {
                Button {
                    Task { await depthModels.download(variant) }
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    /// Which pipeline(s) currently resolve to this model (explicit pick, or
    /// automatic first-installed when the preference is empty).
    private func roleBadges(for name: String) -> [String] {
        var badges: [String] = []
        if effectiveModel(preference: appModel.realtimeDepthModelName) == name {
            badges.append("Real-Time")
        }
        if effectiveModel(preference: appModel.preprocessDepthModelName) == name {
            badges.append("Pre-Process")
        }
        return badges
    }

    private func effectiveModel(preference: String) -> String {
        if !preference.isEmpty, depthModels.installedNames.contains(preference) {
            return preference
        }
        return depthModels.installedNames.first ?? ""
    }

    private func delete(_ name: String) {
        depthModels.delete(name)
        // Clear any preference that pointed at the deleted model ("" = automatic).
        if appModel.realtimeDepthModelName == name {
            appModel.realtimeDepthModelName = ""
        }
        if appModel.preprocessDepthModelName == name {
            appModel.preprocessDepthModelName = ""
        }
    }
}
