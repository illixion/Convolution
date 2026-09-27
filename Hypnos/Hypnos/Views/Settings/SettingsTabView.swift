/*
 Hypnos - Settings Tab View

 Settings view with server configuration and source selection.
 */

import Photos
import RAVEMedia
import os
import SwiftUI
import UniformTypeIdentifiers

/// Outcome of a "Apply & Test Connection" check, carrying whether it should
/// read as good news or bad — a failure (especially `ImageSourceError
/// .mediaAuthenticationFailed`) needs a visibly different treatment than a
/// plain success caption, or it's exactly as missable as the caption-only
/// result this replaced.
enum ConnectionTestOutcome {
    case success(String)
    case failure(String)

    var message: String {
        switch self {
        case .success(let message), .failure(let message):
            return message
        }
    }

    var isFailure: Bool {
        if case .failure = self { return true }
        return false
    }
}

struct SettingsTabView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(MainWindowModel.self) private var windowModel
    @OpenWindowProxy private var openWindow
    @State private var showSaveGroupAlert = false
    @State private var newGroupName = ""
    @State private var showRenameGroupAlert = false
    @State private var renamingGroup: SavedWindowGroup?
    @State private var renameGroupName = ""
    @State private var restoreSheetGroup: SavedWindowGroup?
    /// Depth models discovered in Documents/bundle, for the Fake-3D pickers.
    @State private var depthModels = DepthModelManager.shared
    @State private var showDepthModelManager = false
    #if !os(tvOS)
    @State private var showExporter = false
    @State private var exportDocument: SettingsBackupDocument?
    @State private var isExporting = false
    #endif
    /// Picker + confirmation + alerts, shared with the welcome flow.
    @State private var backupImporter = SettingsBackupImporter()
    @State private var showEnhancementsClearConfirmation = false
    /// Outcome of the last "Apply & Test Connection", shown in place. A
    /// failure needs to read as a failure — a plain caption is easy to miss,
    /// and this is exactly the kind of check whose whole point is catching a
    /// server credential that looks fine (GraphQL still answers) but leaves
    /// every image/video/thumbnail broken (see `verifyStashServer`).
    @State private var connectionTestResult: ConnectionTestOutcome?

    var body: some View {
        @Bindable var appModel = appModel

        NavigationStack {
            List {
                Section("Display") {
                    Toggle("Reduce Motion", isOn: $appModel.reduceMotion)
                    if appModel.systemReduceMotion && !appModel.reduceMotion {
                        Text("Currently enforced by system Accessibility setting.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Diorama thumbnails pop their foreground forward in z.
                    if PlatformCapabilities.supportsDiorama, !appModel.effectiveReduceMotion {
                        Picker("Thumbnail Style", selection: $appModel.thumbnailStyle) {
                            ForEach(ThumbnailStyle.allCases) { style in
                                Text(style.label).tag(style)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    // A window with rounded glass corners is a visionOS
                    // thing; on a phone the photo is content inside the
                    // screen, and rounding it just crops the picture.
                    if PlatformCapabilities.supportsWindowResizing {
                        Toggle("Rounded Corners", isOn: $appModel.roundedCorners)
                    }

                    if PlatformCapabilities.supportsMultipleWindows {
                        Toggle("Always Open In New Window", isOn: $appModel.openMediaInNewWindows)
                    }

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

                    if PlatformCapabilities.supportsSpatial3D {
                        Picker("Default Viewing Mode", selection: $appModel.defaultImageViewingMode) {
                            ForEach(DefaultImageViewingMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    Picker("2D Image Resolution Limit", selection: $appModel.maxImageResolution) {
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

                    if PlatformCapabilities.supportsImmersiveSpaces {
                        Toggle("Fully Immersive 3D Mode", isOn: $appModel.fullyImmersive3DMode)
                    }

                    Toggle("Mute Videos on Open", isOn: $appModel.videoAutoplayMuted)
                    Text("Videos always start playing automatically; turn this off to open them with sound. Applies to video windows and the gallery long-press preview.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // Fake-3D depth models, per pipeline: real-time inference
                    // gates every frame (keep this fast), while pre-process
                    // conversion can afford a slower, higher-quality model.
                    // Models are added/removed in Developer → Depth Model Manager.
                    if PlatformCapabilities.supportsStereoVideo {
                        depthModelPicker(
                            "Real-Time 3D Depth Model",
                            selection: $appModel.realtimeDepthModelName
                        )
                        depthModelPicker(
                            "Pre-Process 3D Depth Model",
                            selection: $appModel.preprocessDepthModelName
                        )
                        Toggle("Real-Time 3D for All Videos", isOn: $appModel.defaultRealtimePseudo3D)
                        Text("Convert to 3D uses these models: Real-Time for instant playback (fast model recommended), Pre-Process for background conversion (a larger model can be used). Manage installed models under Developer. With Real-Time 3D for All Videos on, compatible videos open already converted — using this video's pre-processed conversion when available, otherwise real-time.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if PlatformCapabilities.supportsDiorama {
                        Picker("Diorama Layer Distance", selection: $appModel.dioramaDistance) {
                            ForEach(AppModel.dioramaDistanceOptions, id: \.value) { option in
                                Text(option.label).tag(option.value)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    Picker("Auto-hide Controls After", selection: $appModel.autoHideDelay) {
                        ForEach(AppModel.autoHideDelayOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Delay")
                            Spacer()
                            Text(formatSlideshowDelay(appModel.slideshowDelay))
                                .foregroundColor(.secondary)
                        }
                        #if !os(tvOS)
                        Slider(
                            value: $appModel.slideshowDelay,
                            in: 3...120,
                            step: 1
                        )
                        #endif
                    }

                    Toggle("Show Clock", isOn: $appModel.slideshowShowClock)
                    Toggle("Show Sensors", isOn: $appModel.slideshowShowSensors)
                    Toggle("Fit to Window Aspect Ratio", isOn: $appModel.slideshowUseAspectRatio)
                    Toggle("Ken Burns Effect", isOn: $appModel.slideshowEnableKenBurns)
                    Toggle("Dynamic Brightness", isOn: $appModel.slideshowEnableDynamicBrightness)
                    if PlatformCapabilities.supportsDiorama {
                        Toggle("Diorama Layers", isOn: $appModel.slideshowEnableDiorama)
                    }
                    Toggle("Transparent Background", isOn: $appModel.slideshowTransparentBackground)

                    Picker("Max Image Resolution (2D)", selection: $appModel.slideshowMaxImageResolution2D) {
                        ForEach(AppModel.maxImageResolutionOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .pickerStyle(.menu)

                    if PlatformCapabilities.supportsSpatial3D {
                        Picker("Max Image Resolution (3D)", selection: $appModel.slideshowMaxImageResolution3D) {
                            ForEach(AppModel.maxImageResolutionOptions, id: \.value) { option in
                                Text(option.label).tag(option.value)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Text Size")
                            Spacer()
                            Text(String(format: "%.0f%%", appModel.slideshowTextSize * 100))
                                .foregroundColor(.secondary)
                        }
                        #if !os(tvOS)
                        Slider(value: $appModel.slideshowTextSize, in: 0.5...3.0, step: 0.1)
                        #endif
                    }
                } header: {
                    Text("Slideshow Defaults")
                } footer: {
                    Text("Used when starting a slideshow from any source. Saved Remote API profiles override these per-profile.")
                }

                if PlatformCapabilities.supportsMultipleWindows {
                    windowGroupsSection
                }

                JellyfinServerSection()

                Section("Photo Library") {
                    switch PhotosAuthorization.status {
                    case .authorized:
                        Label("Full library access granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .limited:
                        Label("Access limited to selected photos", systemImage: "checkmark.circle")
                            .foregroundStyle(.yellow)
                        Text("Hypnos can only see the photos you picked. Choose more in Settings → Privacy & Security → Photos.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    case .denied, .restricted:
                        Label("Access denied", systemImage: "xmark.circle")
                            .foregroundStyle(.red)
                        Text("Grant access in Settings → Privacy & Security → Photos to browse your library here.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    default:
                        Button("Allow Access to Photos") {
                            Task { await appModel.requestPhotosAccessAndReload() }
                        }
                        Text("Browse and convert the photos already on this device. Used when no Stash server is configured.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Local Files") {
                    // No toggle — needs no permission and no setup, so unlike
                    // Photos or a media server there is nothing to gate. This
                    // is purely where "where do I put files" gets explained.
                    Text("Browse and convert files you place in this app's Documents folder — in the Files app, under \"On My \(PlatformCapabilities.deviceFamilyName)\" → Hypnos. Always available as a library alongside Photos and any media server.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    TextField("Server URL", text: $appModel.stashServerURL)
                        .textFieldStyle(.plain)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        #if !os(macOS)
                        .keyboardType(.URL)
                        #endif
                        .onSubmit {
                            appModel.updateAPIClient()
                        }

                    SecureField("API Key (optional)", text: $appModel.stashAPIKey)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .onSubmit {
                            appModel.updateAPIClient()
                        }

                    Button("Apply & Test Connection") {
                        appModel.updateAPIClient()
                        connectionTestResult = nil
                        Task {
                            await testConnection()
                        }
                    }

                    if let connectionTestResult {
                        if connectionTestResult.isFailure {
                            Label(connectionTestResult.message, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.red)
                        } else {
                            Text(connectionTestResult.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle("Server-Side Transcoding", isOn: $appModel.enableStashTranscoding)
                    Text("Keep the Stash server's HLS transcode in reserve. Scenes always play their original file first (WebM decodes on-device in WebKit); the transcode is used only if that file can't be played, or when a feature needs AVFoundation — Convert to 3D, immersive 3D, depth pre-processing. Turn off to never transcode, which leaves those unavailable for WebM. Applies to newly loaded scenes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Media Server")
                } footer: {
                    Text("Connects to a self-hosted Stash server to browse and convert its library.")
                }

                NextcloudSettingsSection()

                #if !os(tvOS)
                DeviceSetupSendSection()
                #endif

                Section("Gallery Statistics") {
                    HStack {
                        Text("Images Loaded")
                        Spacer()
                        Text("\(appModel.galleryImages.count)")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Videos Loaded")
                        Spacer()
                        Text("\(appModel.galleryVideos.count)")
                            .foregroundColor(.secondary)
                    }
                }

                CacheSettingsSection()

                // No Files app / document picker on tvOS to export to or
                // import from — this whole section (and the state driving
                // it) only exists on the other platforms.
                #if !os(tvOS)
                Section("Backup") {
                    Button {
                        isExporting = true
                        Task {
                            let backup = await appModel.exportSettingsBackup()
                            let encoder = JSONEncoder()
                            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                            encoder.dateEncodingStrategy = .iso8601
                            if let data = try? encoder.encode(backup) {
                                exportDocument = SettingsBackupDocument(data: data)
                                showExporter = true
                            }
                            isExporting = false
                        }
                    } label: {
                        if isExporting {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Preparing...")
                            }
                        } else {
                            Label("Export Settings", systemImage: "square.and.arrow.up")
                        }
                    }
                    .disabled(isExporting)

                    Button {
                        backupImporter.pickFile()
                    } label: {
                        Label("Import Settings", systemImage: "square.and.arrow.down")
                    }

                    Button {
                        backupImporter.loadNewestFromDocuments()
                    } label: {
                        Label("Import from Documents Folder", systemImage: "folder")
                    }

                    // Says so up front: the file is shareable, and someone who
                    // assumed it was complete would restore onto a server that
                    // silently fails to authenticate.
                    Text("Backups include your server addresses and display settings, but not passwords or API keys — re-enter those after restoring.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                #endif

                Section("Developer") {
                    Toggle("Enable RoboFrame Viewer", isOn: Binding(
                        get: { appModel.enableRemoteViewer },
                        set: { newValue in
                            appModel.enableRemoteViewer = newValue
                            if !newValue && windowModel.selectedTab == .remote {
                                windowModel.selectedTab = .settings
                            }
                        }
                    ))
                    Text("Enable viewer for RoboFrame photo slideshow engine, see README.md for info on backend setup.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("Show Debug Console", isOn: Binding(
                        get: { appModel.showDebugConsole },
                        set: { newValue in
                            appModel.showDebugConsole = newValue
                            if !newValue && windowModel.selectedTab == .console {
                                windowModel.selectedTab = .settings
                            }
                        }
                    ))
                    Text("Adds a Console tab showing app log messages in real time.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("Respect System Memory Alerts", isOn: $appModel.respectMemoryAlerts)
                    Text("When disabled, the app will not unload images or downscale windows in response to system memory pressure.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("Lossy Texture Compression", isOn: $appModel.useLossyTextureCompression)
                    Text("Reduces GPU memory per image by ~2-4x using hardware lossy compression. Slight quality reduction. New images use the updated setting; existing windows are unaffected until reloaded.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // Fake-3D depth models are managed (added/downloaded/deleted)
                    // in a dedicated modal; which model each pipeline USES is
                    // picked in the Display section's two dropdowns.
                    if PlatformCapabilities.supportsStereoVideo {
                        Button {
                            showDepthModelManager = true
                        } label: {
                            Label("Depth Model Manager", systemImage: "shippingbox")
                        }
                        if let downloading = DepthModelManager.variants.first(where: { depthModels.isDownloading($0) }) {
                            HStack(spacing: 12) {
                                ProgressView(value: depthModels.progress[downloading.name] ?? 0)
                                Text("Downloading \(downloading.displayName)…")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Text("Pseudo 3D video requires a monocular depth model (~19–50 MB, downloaded from Apple's Hugging Face repo). Videos already pre-processed keep playing in 3D even without a model.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        // Pre-processed fake-3D depth caches (Convert to 3D → Pre-Process).
                        DepthCacheSettingsView()
                    }

                    Button {
                        openWindow(id: "gpu-memory")
                    } label: {
                        Label("Open GPU Memory Monitor", systemImage: "memorychip")
                    }
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

                Section("About") {
                    HStack {
                        Text("App Name")
                        Spacer()
                        Text("Hypnos")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersionString)
                            .foregroundColor(.secondary)
                    }
                    Button("Show Welcome Screen Again") {
                        appModel.hasCompletedWelcome = false
                    }
                }
            }
            .navigationTitle("Settings")
            .task {
                depthModels.importInboxIfNeeded()
            }
            .sheet(isPresented: $showDepthModelManager) {
                DepthModelManagerSheet()
                    .environment(appModel)
            }
            .alert("Save Window Group", isPresented: $showSaveGroupAlert) {
                TextField("Group Name", text: $newGroupName)
                Button("Save") {
                    let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        appModel.saveCurrentWindowGroup(name: name)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter a name for this arrangement of \(openWindowCount) open \(openWindowCount == 1 ? "window" : "windows"). Each window's position is remembered by visionOS; the group remembers what it showed and how big it was.")
            }
            .alert("Rename Window Group", isPresented: $showRenameGroupAlert) {
                TextField("Group Name", text: $renameGroupName)
                Button("Rename") {
                    let name = renameGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty, let group = renamingGroup {
                        appModel.renameSavedWindowGroup(group, newName: name)
                    }
                    renamingGroup = nil
                }
                Button("Cancel", role: .cancel) {
                    renamingGroup = nil
                }
            } message: {
                Text("Enter a new name for this window group.")
            }
            .sheet(item: $restoreSheetGroup) { group in
                WindowGroupRestoreSheet(group: group)
                    .environment(appModel)
            }
            #if !os(tvOS)
            .fileExporter(
                isPresented: $showExporter,
                document: exportDocument,
                contentType: .json,
                defaultFilename: "Hypnos-Backup-\(backupDateString()).json"
            ) { _ in
                exportDocument = nil
            }
            #endif
            .settingsBackupImport(backupImporter)
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

    // MARK: - Window Groups

    /// Number of open windows a group would capture right now. Extracted (like
    /// the whole section below) because inlining it in the `List` blew past the
    /// type-checker's budget for that expression.
    private var openWindowCount: Int {
        appModel.openWindowEntries.count
    }

    @ViewBuilder
    private var windowGroupsSection: some View {
        Section {
            Button("Save Current Windows") {
                newGroupName = ""
                showSaveGroupAlert = true
            }
            .disabled(openWindowCount == 0)

            if appModel.savedWindowGroups.isEmpty {
                Text("No saved window groups")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appModel.savedWindowGroups) { group in
                    windowGroupRow(group)
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        appModel.deleteSavedWindowGroup(appModel.savedWindowGroups[index])
                    }
                }
            }
        } header: {
            Text("Window Groups")
        } footer: {
            Text("Saves every open pop-out window — photos, videos, RoboFrame slideshows and pinned web pages — and restores each one at the size it was saved at.")
        }
    }

    @ViewBuilder
    private func windowGroupRow(_ group: SavedWindowGroup) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(group.name)
                Text("\(group.contentSummary) \u{00B7} \(group.savedDate, style: .date)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Rename") {
                renamingGroup = group
                renameGroupName = group.name
                showRenameGroupAlert = true
            }
            .buttonStyle(.borderless)
            Button("Restore All") {
                appModel.restoreWindowGroup(group)
            }
            .buttonStyle(.borderless)
            Button("Restore...") {
                restoreSheetGroup = group
            }
            .buttonStyle(.borderedProminent)
        }
    }

    /// Verifies the server fields as typed. Goes through the model's shared
    /// check rather than `imageSource`, which on a Photos library would have
    /// been testing the photo library and reporting success either way.
    private func testConnection() async {
        do {
            let count = try await appModel.verifyStashServer(url: appModel.stashServerURL,
                                                            apiKey: appModel.stashAPIKey)
            connectionTestResult = .success("Connected — \(count) image\(count == 1 ? "" : "s")")
            AppLogger.settings.info("Connection successful, \(count, privacy: .public) images")
        } catch {
            connectionTestResult = .failure(error.localizedDescription)
            AppLogger.settings.error("Connection failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func backupDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func formatSlideshowDelay(_ seconds: TimeInterval) -> String {
        let intSeconds = Int(seconds)
        if intSeconds >= 60 {
            let minutes = intSeconds / 60
            let remainingSeconds = intSeconds % 60
            if remainingSeconds == 0 {
                return "\(minutes) min"
            } else {
                return "\(minutes) min \(remainingSeconds) sec"
            }
        } else {
            return "\(intSeconds) seconds"
        }
    }

    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let commitHash = Bundle.main.infoDictionary?["CommitHash"] as? String
        if let commitHash, !commitHash.isEmpty, commitHash != "unknown" {
            return "\(version) (\(commitHash))"
        }
        return version
    }

}
