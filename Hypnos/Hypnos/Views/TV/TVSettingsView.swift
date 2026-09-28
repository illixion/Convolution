/*
 Hypnos - tvOS Settings tab

 A remote-friendly subset of `SettingsTabView`: servers, library source and
 cache — the things a TV-only install actually needs to configure.
 Deliberately leaves out everything that's either free-form-slider-shaped
 (display adjustments, slideshow tuning) or belongs to a feature that isn't
 on tvOS at all (spatial 3D, depth models, backup import/export — no Files
 app to pick a file from). See `Hypnos/CLAUDE.md` "tvOS".

 Laid out like the tvOS Settings app: a short top page of rows, each showing
 its current value and opening its own page. tvOS has no disclosure groups,
 and one long form buried the cache under every server's fields.

 Choices are full-width checkmarked rows, never a `Picker`. Its default
 style pushes a list that stalls on a blank page inside the tab bar (tvOS 27,
 "_UIReplicantView as a subview of UIHostingController.view"), and its menu
 style draws a pill sized to its label that the focus engine can't move
 past. For the same reason no row carries a trailing button: moving down the
 list only reaches controls that span it. `CacheSettingsSection`,
 `NextcloudSettingsSection` and `JellyfinServerSection` follow this on tvOS.
 */

#if os(tvOS)

import RAVEDeviceSetup
import SwiftUI

enum TVSettingsPage: String, Hashable {
    case deviceSetup, librarySource, jellyfin, stash, nextcloud, cache, developer
}

/// Settings state that has to outlive the view. When the tab bar gains or
/// loses a tab (Library appears once Jellyfin is configured) tvOS rebuilds
/// the other tabs' content, and view `@State` goes with it: a pushed page
/// went blank with no way back (tvOS 27). Kept here, a rebuild lands back
/// on the same page — including Set Up from Another Device's result, whose
/// payload is exactly what adds the Library tab.
@MainActor
@Observable
final class TVSettingsState {
    static let shared = TVSettingsState()

    var path: [TVSettingsPage] = [] {
        didSet {
            if !path.contains(.deviceSetup) { endDeviceSetup() }
        }
    }

    /// The setup page's receiver and what it received, while that page is
    /// in `path`.
    private(set) var setupReceiver: RAVESetupReceiver<DeviceSetupPayload>?
    private(set) var setupReceived: DeviceSetupPayload?

    private init() {
        // DEBUG-only, like `tvInitialTab`: `-UITestDefault
        // tvSettingsInitialPage=deviceSetup` opens that page, since the
        // simulator takes no remote presses.
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "tvSettingsInitialPage"), let page = TVSettingsPage(rawValue: raw) {
            path = [page]
        }
        #endif
    }

    /// Starts listening unless a receiver is already up or has finished.
    func beginDeviceSetup(applying apply: @escaping @MainActor (DeviceSetupPayload) -> Void) {
        guard setupReceiver == nil, setupReceived == nil else { return }
        let receiver = RAVESetupReceiver<DeviceSetupPayload>(service: DeviceSetup.service) { [weak self] payload in
            apply(payload)
            self?.setupReceived = payload
        }
        receiver.start()
        setupReceiver = receiver
    }

    private func endDeviceSetup() {
        setupReceiver?.stop()
        setupReceiver = nil
        setupReceived = nil
    }
}

struct TVSettingsView: View {
    private typealias Page = TVSettingsPage

    @Environment(AppModel.self) private var appModel
    @Bindable private var film = FilmSession.shared
    @Bindable private var jellyfin = JellyfinAuth.shared
    @Bindable private var state = TVSettingsState.shared
    @State private var cachePreset = CacheBudget.preset

    var body: some View {
        NavigationStack(path: $state.path) {
            Form {
                Section {
                    row(.deviceSetup, "Set Up from Another Device", systemImage: "qrcode", value: "")
                }
                Section {
                    row(.librarySource, "Library Source", systemImage: appModel.effectiveLibrarySource.symbolName,
                        value: appModel.effectiveLibrarySource.displayName)
                }
                Section("Servers") {
                    row(.jellyfin, "Jellyfin", systemImage: "film.stack", value: jellyfinStatus)
                    row(.stash, "Stash", systemImage: LibrarySource.stash.symbolName,
                        value: appModel.hasStashServer ? host(appModel.stashServerURL) : "Not set")
                    row(.nextcloud, "Nextcloud", systemImage: LibrarySource.nextcloud.symbolName,
                        value: appModel.hasNextcloudServer ? host(appModel.nextcloudServerURL) : "Not set")
                }
                Section {
                    row(.cache, "Cache", systemImage: "internaldrive", value: cachePreset.label)
                    row(.developer, "Developer", systemImage: "hammer", value: "")
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: Page.self) { page in
                if page == .deviceSetup {
                    // A QR code and instructions, not a list.
                    TVDeviceSetupView()
                } else {
                    Form { content(for: page) }
                        .navigationTitle(title(for: page))
                }
            }
            // The preset isn't observable; pick up a change made on the
            // Cache page when coming back.
            .onAppear { cachePreset = CacheBudget.preset }
        }
    }

    private func row(_ page: Page, _ title: String, systemImage: String, value: String) -> some View {
        NavigationLink(value: page) {
            LabeledContent {
                Text(value)
            } label: {
                Label(title, systemImage: systemImage)
            }
        }
    }

    private var jellyfinStatus: String {
        if let user = jellyfin.session { return user.userName }
        return film.server.isEmpty ? "Not set" : host(film.server)
    }

    private func host(_ url: String) -> String {
        URL(string: url)?.host ?? url
    }

    private func title(for page: Page) -> String {
        switch page {
        case .deviceSetup: "Set Up from Another Device"
        case .librarySource: "Library Source"
        case .jellyfin: "Jellyfin"
        case .stash: "Stash"
        case .nextcloud: "Nextcloud"
        case .cache: "Cache"
        case .developer: "Developer"
        }
    }

    @ViewBuilder
    private func content(for page: Page) -> some View {
        switch page {
        case .deviceSetup: EmptyView()
        case .librarySource: TVLibrarySourceSection { state.path.removeLast() }
        case .jellyfin: JellyfinServerSection()
        case .stash: TVStashServerSection()
        case .nextcloud: NextcloudSettingsSection()
        case .cache: CacheSettingsSection()
        case .developer: TVDeveloperSection()
        }
    }
}

private struct TVDeveloperSection: View {
    @Environment(AppModel.self) private var appModel
    @Bindable private var film = FilmSession.shared

    var body: some View {
        @Bindable var appModel = appModel
        Section {
            Toggle("Show Object Map", isOn: $film.showMap)
        } header: {
            Text("Film Player")
        } footer: {
            Text("Draws where a film's sound objects are, from above and from the front, with how many are sounding and overhead. The player's Show Objects button toggles the same setting.")
        }
        Section {
            Toggle("Show Debug Console", isOn: $appModel.showDebugConsole)
            Toggle("Respect System Memory Alerts", isOn: $appModel.respectMemoryAlerts)
        } footer: {
            Text("The console adds a tab showing the app's log messages as they arrive. With memory alerts ignored, the app won't unload images when the system is short of memory.")
        }
    }
}

/// One checkmarked row per available source; choosing one goes back.
private struct TVLibrarySourceSection: View {
    @Environment(AppModel.self) private var appModel
    let onChoose: () -> Void

    var body: some View {
        Section {
            ForEach(appModel.availableLibrarySources, id: \.self) { source in
                Button {
                    appModel.librarySource = source
                    onChoose()
                } label: {
                    HStack {
                        Label(source.displayName, systemImage: source.symbolName)
                        Spacer()
                        if source == appModel.effectiveLibrarySource {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } footer: {
            Text("Local Files browses files placed in this app's Documents folder. Stash and Nextcloud appear once their server is set up.")
        }
    }
}

private struct TVStashServerSection: View {
    @Environment(AppModel.self) private var appModel
    @State private var connectionTestResult: ConnectionTestOutcome?

    var body: some View {
        Section {
            TextField("Server URL", text: Binding(
                get: { appModel.stashServerURL },
                set: { appModel.stashServerURL = $0 }
            ))
            .autocorrectionDisabled()

            SecureField("API Key (optional)", text: Binding(
                get: { appModel.stashAPIKey },
                set: { appModel.stashAPIKey = $0 }
            ))

            Button("Apply & Test Connection") {
                appModel.updateAPIClient()
                connectionTestResult = nil
                Task { await testConnection() }
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

            Toggle("Server-Side Transcoding", isOn: Binding(
                get: { appModel.enableStashTranscoding },
                set: { appModel.enableStashTranscoding = $0 }
            ))
        } footer: {
            Text("Connects to a self-hosted Stash server to browse and convert its library.")
        }
    }

    private func testConnection() async {
        do {
            let count = try await appModel.verifyStashServer(
                url: appModel.stashServerURL,
                apiKey: appModel.stashAPIKey
            )
            connectionTestResult = .success("Connected — \(count) image\(count == 1 ? "" : "s")")
        } catch {
            connectionTestResult = .failure(error.localizedDescription)
        }
    }
}

#endif
