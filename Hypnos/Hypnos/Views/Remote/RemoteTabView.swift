/*
 Hypnos - Remote Tab View

 Configuration interface for Remote API Viewer instances. Tag lists,
 blocked posts, and blocked tags are owned by the RoboFrame server and
 synced over the WebSocket; this view edits per-viewer display settings
 and the local "Default List" preference.

 Everything below the profile list is a *draft*. Nothing reaches
 `savedRemoteConfigs` until an explicit Save (or a Save & Launch), and the
 Editing section always names the profile a Save would overwrite plus
 whether the draft currently differs from it — so "am I about to change a
 saved profile?" is answerable without remembering what was loaded.

 Open viewer windows write their own ornament tweaks back into the same
 store (`RemoteViewerModel.onConfigChanged`). A clean draft silently follows
 those; a draft with edits of its own can't, so it gets flagged rather than
 letting the next Save quietly revert the window's change.
 */

import SwiftUI

struct RemoteTabView: View {
    @Environment(AppModel.self) private var appModel

    /// The profile being edited. Only ever persisted through `save()`.
    @State private var editingConfig: RemoteViewerConfig

    /// The draft as it looked at load / new / save time. "Has the user
    /// changed anything" is exactly `editingConfig != baseline`.
    @State private var baseline: RemoteViewerConfig

    /// A load / new-draft request parked behind the discard confirmation.
    @State private var pendingSwitch: PendingSwitch?

    /// Set when the loaded profile changed in the store while this draft had
    /// unsaved edits — saving would replace whatever changed it.
    @State private var storeChangedUnderDraft = false

    @State private var didSeedDefaults = false
    @State private var newModTagPreset = ""

    /// What a discard confirmation is holding up.
    private enum PendingSwitch: Equatable {
        case load(UUID)
        case newDraft
    }

    init() {
        // Both start as the same value (same `id`), so a freshly opened
        // editor reads as an untouched new draft rather than a modified one.
        let draft = RemoteViewerConfig(name: "New Configuration")
        _editingConfig = State(initialValue: draft)
        _baseline = State(initialValue: draft)
    }

    // MARK: - Draft state

    /// The stored profile this draft would overwrite. `nil` when the draft has
    /// never been saved — or when its profile was deleted elsewhere, which is
    /// the same situation from the draft's point of view: a Save creates a row.
    private var storedCopy: RemoteViewerConfig? {
        appModel.savedRemoteConfigs.first { $0.id == editingConfig.id }
    }

    private var isNewDraft: Bool { storedCopy == nil }

    private var hasUnsavedChanges: Bool { editingConfig != baseline }

    private var trimmedName: String {
        editingConfig.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A Save is only meaningful when there's something to write.
    private var canSave: Bool {
        !trimmedName.isEmpty && (isNewDraft || hasUnsavedChanges)
    }

    /// Launching always opens a *saved* profile, so a draft that differs from
    /// the store has to be written first.
    private var needsSaveToLaunch: Bool { isNewDraft || hasUnsavedChanges }

    var body: some View {
        NavigationStack {
            List {
                savedConfigurationsSection
                editingSection

                Section {
                    Picker("Mode", selection: $editingConfig.mode) {
                        ForEach(RemoteViewerMode.userSelectable) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Mode")
                } footer: {
                    Text(editingConfig.mode == .webPage
                         ? "Pins a website in your space. The page keeps its state and window size; it only accepts input while the ornaments are visible."
                         : "Slideshow driven by a RoboFrame server. For a slideshow of the pictures, videos or folder you're browsing, use the play button at the end of the tab bar instead.")
                }

                if editingConfig.mode == .webPage {
                    webPageSection
                } else {
                    slideshowSections
                }

                Section {
                    Button {
                        launchDraft()
                    } label: {
                        Text(launchButtonTitle)
                            .foregroundStyle(.blue)
                    }
                    .disabled(trimmedName.isEmpty || !editingConfig.isLaunchable)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let reason = editingConfig.launchBlockedReason {
                            Text(reason)
                                .foregroundStyle(.red)
                        }
                        if needsSaveToLaunch {
                            Text(isNewDraft
                                 ? "Saves the draft as a new profile first — launching always opens a saved profile."
                                 : "Saves your changes to “\(storedCopy?.name ?? trimmedName)” first — launching always opens a saved profile.")
                        }
                    }
                }
            }
            .navigationTitle("Remote Viewer")
            .onAppear(perform: seedDefaultsIfUntouched)
            .onChange(of: appModel.savedRemoteConfigs) { _, _ in
                adoptStoreChange()
            }
            .confirmationDialog(
                pendingSwitchTitle,
                isPresented: Binding(
                    get: { pendingSwitch != nil },
                    set: { if !$0 { pendingSwitch = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button(isNewDraft ? "Save as New Profile and Continue" : "Save Changes and Continue") {
                    resolvePendingSwitch(saveFirst: true)
                }
                Button("Discard Changes", role: .destructive) {
                    resolvePendingSwitch(saveFirst: false)
                }
                Button("Cancel", role: .cancel) { pendingSwitch = nil }
            }
        }
    }

    // MARK: - Saved configurations

    @ViewBuilder
    private var savedConfigurationsSection: some View {
        Section {
            if appModel.savedRemoteConfigs.isEmpty {
                Text("No saved configurations")
                    .foregroundColor(.secondary)
            } else {
                ForEach(appModel.savedRemoteConfigs) { config in
                    savedConfigRow(config)
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        appModel.deleteRemoteConfig(appModel.savedRemoteConfigs[index])
                    }
                }
            }
        } header: {
            HStack {
                Text("Saved Configurations")
                Spacer()
                Button {
                    requestNewDraft()
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
            .textCase(nil)
        } footer: {
            Text("Launch opens the saved version of a profile; unsaved edits stay in the editor below.")
        }
    }

    @ViewBuilder
    private func savedConfigRow(_ config: RemoteViewerConfig) -> some View {
        let isEditing = config.id == editingConfig.id

        HStack {
            Image(systemName: config.mode.systemImage)
                .foregroundStyle(.secondary)
                .help(config.mode.label)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(config.name)
                    if isEditing {
                        Text(hasUnsavedChanges ? "Editing · unsaved" : "Editing")
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(
                                hasUnsavedChanges ? Color.orange.opacity(0.3) : Color.secondary.opacity(0.2),
                                in: .capsule
                            )
                    }
                }
                if let reason = config.launchBlockedReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text(config.savedDate, style: .date)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Button(isEditing ? "Reload" : "Load") {
                requestLoad(config)
            }
            .buttonStyle(.borderless)
            .disabled(isEditing && !hasUnsavedChanges)
            Button("Copy") {
                appModel.saveRemoteConfig(
                    config.duplicated(name: uniqueName(from: config.name + " (Copy)"))
                )
            }
            .buttonStyle(.borderless)
            Button("Launch") {
                launchViewer(config: config)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!config.isLaunchable)
        }
    }

    // MARK: - Editing status

    @ViewBuilder
    private var editingSection: some View {
        Section {
            TextField("Name", text: $editingConfig.name)
                .textFieldTapTarget()

            HStack(spacing: 8) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusTint)
                Text(statusText)
                    .font(.callout)
                Spacer()
            }

            if storeChangedUnderDraft {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("This profile changed in an open viewer window.")
                        Text("Saving replaces that change with your edits.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Reload") { revertToStored() }
                        .buttonStyle(.bordered)
                }
            }

            HStack {
                Button(isNewDraft ? "Save as New Profile" : "Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                Button("Revert") { revertToStored() }
                    .buttonStyle(.bordered)
                    .disabled(isNewDraft || !hasUnsavedChanges)
                Spacer()
                if !isNewDraft {
                    Button("Save as Copy") { saveAsNew() }
                        .buttonStyle(.bordered)
                        .disabled(trimmedName.isEmpty)
                }
            }
        } header: {
            Text("Editing")
        } footer: {
            Text(isNewDraft
                 ? "Nothing is written until you save. Launching saves first."
                 : "“Save as Copy” branches these settings into a new profile instead of overwriting “\(storedCopy?.name ?? trimmedName)”.")
        }
    }

    private var statusSymbol: String {
        if isNewDraft { return "doc.badge.plus" }
        return hasUnsavedChanges ? "pencil.circle.fill" : "checkmark.circle.fill"
    }

    private var statusTint: Color {
        if isNewDraft { return .secondary }
        return hasUnsavedChanges ? .orange : .green
    }

    private var statusText: String {
        guard let stored = storedCopy else {
            return "New profile — not saved yet"
        }
        return hasUnsavedChanges
            ? "Unsaved changes to “\(stored.name)”"
            : "Matches the saved profile “\(stored.name)”"
    }

    private var launchButtonTitle: String {
        let verb = editingConfig.mode == .webPage ? "Open Website" : "Launch Viewer"
        return needsSaveToLaunch ? "Save & \(verb)" : verb
    }

    private var pendingSwitchTitle: String {
        guard let stored = storedCopy else {
            return "“\(trimmedName)” hasn't been saved yet"
        }
        return "“\(stored.name)” has unsaved changes"
    }

    // MARK: - Draft actions

    private func save() {
        var config = editingConfig
        config.name = trimmedName.isEmpty ? "Untitled" : trimmedName
        editingConfig = config
        appModel.saveRemoteConfig(config)
        baseline = config
        storeChangedUnderDraft = false
    }

    /// Branch the draft into a fresh profile, leaving the one it was loaded
    /// from untouched. The escape hatch when settings were tweaked for a
    /// one-off and shouldn't land on the original.
    private func saveAsNew() {
        let copy = editingConfig.duplicated(name: uniqueName(from: trimmedName))
        appModel.saveRemoteConfig(copy)
        editingConfig = copy
        baseline = copy
        storeChangedUnderDraft = false
    }

    /// Throw away the draft's edits and re-read the profile from the store —
    /// which also picks up anything an open viewer window wrote meanwhile.
    private func revertToStored() {
        guard let stored = storedCopy else { return }
        editingConfig = stored
        baseline = stored
        storeChangedUnderDraft = false
    }

    private func requestLoad(_ config: RemoteViewerConfig) {
        guard hasUnsavedChanges else {
            load(config)
            return
        }
        pendingSwitch = .load(config.id)
    }

    private func requestNewDraft() {
        guard hasUnsavedChanges else {
            newDraft()
            return
        }
        pendingSwitch = .newDraft
    }

    private func load(_ config: RemoteViewerConfig) {
        var config = config
        // The Mode picker only lists the user-selectable modes; a profile
        // carrying anything else (a restored backup from a build that stored
        // one) would leave the picker showing nothing.
        if !RemoteViewerMode.userSelectable.contains(config.mode) {
            config.mode = .slideshow
        }
        editingConfig = config
        baseline = config
        storeChangedUnderDraft = false
        // A loaded profile carries its own display settings; re-seeding the
        // app-level slideshow defaults over them would be an overwrite.
        didSeedDefaults = true
    }

    private func newDraft() {
        var draft = RemoteViewerConfig(name: uniqueName(from: "New Configuration"))
        appModel.applySlideshowDefaults(to: &draft)
        editingConfig = draft
        baseline = draft
        storeChangedUnderDraft = false
        didSeedDefaults = true
    }

    private func resolvePendingSwitch(saveFirst: Bool) {
        let pending = pendingSwitch
        pendingSwitch = nil
        if saveFirst { save() }
        switch pending {
        case .load(let id):
            if let config = appModel.savedRemoteConfigs.first(where: { $0.id == id }) {
                load(config)
            }
        case .newDraft:
            newDraft()
        case nil:
            break
        }
    }

    private func launchDraft() {
        if needsSaveToLaunch { save() }
        launchViewer(config: editingConfig)
    }

    /// Seed the untouched draft with the user's slideshow defaults the first
    /// time the editor is shown. Once anything is loaded or edited the
    /// defaults stop being relevant.
    private func seedDefaultsIfUntouched() {
        guard !didSeedDefaults, isNewDraft, !hasUnsavedChanges else { return }
        var seeded = editingConfig
        appModel.applySlideshowDefaults(to: &seeded)
        editingConfig = seeded
        baseline = seeded
        didSeedDefaults = true
    }

    /// An open viewer window persists ornament tweaks straight into
    /// `savedRemoteConfigs`. A clean draft just follows along; a draft with
    /// edits of its own can't, so flag it instead of letting the next Save
    /// quietly revert the window's change.
    private func adoptStoreChange() {
        guard let stored = storedCopy, stored != baseline else { return }
        if hasUnsavedChanges {
            storeChangedUnderDraft = true
        } else {
            editingConfig = stored
            baseline = stored
        }
    }

    /// A name no saved profile is using yet, so copies and new drafts can't
    /// produce rows the user has no way to tell apart.
    private func uniqueName(from base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? "New Configuration" : trimmed
        let taken = Set(appModel.savedRemoteConfigs.map(\.name))
        guard taken.contains(candidate) else { return candidate }
        var index = 2
        while taken.contains("\(candidate) \(index)") { index += 1 }
        return "\(candidate) \(index)"
    }

    // MARK: - Website mode

    @ViewBuilder
    private var webPageSection: some View {
        Section {
            TextField("Page URL", text: $editingConfig.webPageURL)
                .textFieldTapTarget()
                .textContentType(.URL)
                .autocorrectionDisabled()
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                #endif
                #if !os(macOS)
                .keyboardType(.URL)
                #endif

            if !editingConfig.webPageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               editingConfig.resolvedWebPageURL == nil {
                Text("Not a usable URL.")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let resolved = editingConfig.resolvedWebPageURL,
                      resolved.absoluteString != editingConfig.webPageURL.trimmingCharacters(in: .whitespacesAndNewlines) {
                Text("Opens \(resolved.absoluteString)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Toggle("Transparent Background", isOn: $editingConfig.webTransparentBackground)
            Text("Injects CSS so the page's own background paints through to your space. Pages that set a background on an inner element still paint it.")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Auto-Refresh")
                    Spacer()
                    Text(RemoteViewerConfig.webAutoRefreshLabel(editingConfig.webAutoRefreshInterval))
                        .foregroundColor(.secondary)
                }
                #if !os(tvOS)
                Slider(
                    value: autoRefreshIndex,
                    in: 0...Double(RemoteViewerConfig.webAutoRefreshOptions.count - 1),
                    step: 1
                )
                #endif
                Text("Reloads the page after this long with no interaction. Off by default.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Website")
        } footer: {
            Text("Tap the window to reveal the controls and unlock the page; hide them again (eye button, or let them auto-hide) to block input and stop visionOS from highlighting links as you look around.")
        }
    }

    /// Slider position for the auto-refresh interval. Snaps to the nearest
    /// preset so a value restored from an older build (or a backup) still lands
    /// on a real stop instead of reading as "Off".
    private var autoRefreshIndex: Binding<Double> {
        Binding(
            get: {
                let options = RemoteViewerConfig.webAutoRefreshOptions
                let current = editingConfig.webAutoRefreshInterval
                let nearest = options.enumerated().min { lhs, rhs in
                    abs(lhs.element - current) < abs(rhs.element - current)
                }
                return Double(nearest?.offset ?? 0)
            },
            set: { newValue in
                let options = RemoteViewerConfig.webAutoRefreshOptions
                let index = min(max(Int(newValue.rounded()), 0), options.count - 1)
                editingConfig.webAutoRefreshInterval = options[index]
            }
        )
    }

    // MARK: - RoboFrame mode

    @ViewBuilder
    private var slideshowSections: some View {
        Section {
            TextField("RoboFrame API Endpoint", text: $editingConfig.apiEndpoint)
                .textFieldTapTarget()
                .textContentType(.URL)
                .autocorrectionDisabled()
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                #endif

            TextField("WebSocket Device ID", text: $editingConfig.wsDeviceId)
                .textFieldTapTarget()
                .autocorrectionDisabled()
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                #endif

            Text("Home Assistant uses this stable ID. The server keeps each window's slideshow session independent.")
                .font(.caption)
                .foregroundColor(.secondary)

            SecureField("Access Token", text: $editingConfig.accessToken)
                .textFieldTapTarget()
                .autocorrectionDisabled()
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                #endif

            Link("RoboFrame on GitHub", destination: RemoteViewerConfig.roboFrameRepositoryURL)
                .font(.caption)
        } header: {
            Text("RoboFrame Server")
        } footer: {
            Text("Leave the endpoint blank to run the slideshow off this app's own gallery instead of a RoboFrame server.")
        }

        Section("Display") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Image Interval")
                    Spacer()
                    Text(formatDelay(editingConfig.delay))
                        .foregroundColor(.secondary)
                }
                #if !os(tvOS)
                Slider(value: $editingConfig.delay, in: 3...120, step: 1)
                #endif
            }

            if PlatformCapabilities.supportsSpatial3D {
                Picker("3D Mode", selection: $editingConfig.slideshow3DMode) {
                    ForEach(Slideshow3DMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            }

            Toggle("Show Clock", isOn: $editingConfig.showClock)
            Toggle("Show Sensors", isOn: $editingConfig.showSensors)
            Toggle("Fit to Window Aspect Ratio", isOn: $editingConfig.useAspectRatio)
            Toggle("Ken Burns Effect", isOn: $editingConfig.enableKenBurns)
            Toggle("Transparent Background", isOn: $editingConfig.transparentBackground)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Text Size")
                    Spacer()
                    Text(String(format: "%.0f%%", editingConfig.textSize * 100))
                        .foregroundColor(.secondary)
                }
                #if !os(tvOS)
                Slider(value: $editingConfig.textSize, in: 0.5...3.0, step: 0.1)
                #endif
            }
        }

        modTagPresetsSection
    }

    // MARK: - Mod tag presets (local)

    /// Mod tags don't persist on the server — they modify the active query
    /// for whichever channel this device is on. The catalog of presets
    /// lives entirely on this device; switching presets in the ornament
    /// pushes the active set to the server (and clears its query cache).
    ///
    /// Deliberately outside the draft/Save flow: these are device-wide, not
    /// per-profile, so they apply the moment they're edited.
    @ViewBuilder
    private var modTagPresetsSection: some View {
        let mtm = appModel.modTagManager
        let bindable = Binding(
            get: { mtm.modTagLists },
            set: { mtm.modTagLists = $0 }
        )

        Section {
            ForEach(mtm.modTagLists.indices, id: \.self) { index in
                HStack {
                    Text("Preset \(index + 1)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 70, alignment: .leading)
                    TextField(
                        "Tags (space-separated)",
                        text: Binding(
                            get: {
                                guard index < mtm.modTagLists.count else { return "" }
                                return mtm.modTagLists[index].joined(separator: " ")
                            },
                            set: { newValue in
                                guard index < bindable.wrappedValue.count else { return }
                                bindable.wrappedValue[index] = newValue
                                    .components(separatedBy: " ")
                                    .filter { !$0.isEmpty }
                            }
                        )
                    )
                    .textFieldTapTarget()
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    #endif
                }
            }
            .onDelete { indexSet in
                bindable.wrappedValue.remove(atOffsets: indexSet)
            }

            HStack {
                TextField("Tags (space-separated)", text: $newModTagPreset)
                    .textFieldTapTarget()
                    .autocorrectionDisabled()
                    #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Button("Add Preset") {
                    let tags = newModTagPreset.trimmingCharacters(in: .whitespaces)
                        .components(separatedBy: " ")
                        .filter { !$0.isEmpty }
                    if !tags.isEmpty {
                        var lists = mtm.modTagLists
                        lists.append(tags)
                        mtm.modTagLists = lists
                        newModTagPreset = ""
                    }
                }
                .disabled(newModTagPreset.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Picker("Default Preset", selection: Binding(
                get: { mtm.defaultIndex ?? -1 },
                set: { mtm.defaultIndex = $0 == -1 ? nil : $0 }
            )) {
                Text("None").tag(-1)
                ForEach(mtm.modTagLists.indices, id: \.self) { index in
                    Text("Preset \(index + 1): \(index < mtm.modTagLists.count ? (mtm.modTagLists[index].first ?? "") : "")").tag(index)
                }
            }
            .pickerStyle(.menu)
        } header: {
            Text("Mod Tag Presets")
        } footer: {
            Text("Shared by every RoboFrame window on this device — saved as you type, not part of the profile above.")
        }
    }

    private func launchViewer(config: RemoteViewerConfig) {
        appModel.enqueueRemoteViewerOpen(configId: config.id)
    }

    private func formatDelay(_ seconds: TimeInterval) -> String {
        let intSeconds = Int(seconds)
        if intSeconds >= 60 {
            let minutes = intSeconds / 60
            let remainingSeconds = intSeconds % 60
            if remainingSeconds == 0 {
                return "\(minutes) min"
            }
            return "\(minutes) min \(remainingSeconds) sec"
        }
        return "\(intSeconds) seconds"
    }
}
