/*
 Hypnos - Settings (visionOS, iOS, macOS)

 A short first page of rows, each showing its current value and opening a
 page of its own, the way tvOS's Settings (`TVSettingsView`) already worked:
 one long list had servers in the middle, nineteen unrelated rows under
 "Display", and test tools at the top level for everyone. Libraries and
 servers come first, then Device Setup, how things look and play, AI 3D,
 storage, and Developer last.

 macOS shows only what its own windows read: the library choice (its sidebar
 has no switch), servers, Device Setup, Cache and Backup.
 */

import RAVEMedia
import SwiftUI

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
    @Bindable private var film = FilmSession.shared
    @Bindable private var jellyfin = JellyfinAuth.shared
    #if HYPNOS_YOUTUBE
    /// No YouTube page until the YouTube tab has been turned on once.
    @AppStorage(YouTubeConsent.defaultsKey) private var youTubeOn = false
    #endif
    /// Not observable; picked up again when coming back from the Cache page.
    @State private var cachePreset = CacheBudget.preset

    enum Page: Hashable {
        case jellyfin, stash, nextcloud, photoLibrary, localFiles, deviceSetup
        case general, gallery, photos, videos, ai3D, slideshows, windowGroups
        case cache, backup, developer
        #if HYPNOS_YOUTUBE
        case youtube
        #endif
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Libraries & Servers") {
                    row(.jellyfin, "Jellyfin", systemImage: "film.stack", value: jellyfinStatus)
                    row(.stash, "Stash", systemImage: LibrarySource.stash.symbolName,
                        value: appModel.hasStashServer ? host(appModel.stashServerURL) : "Not Set")
                    row(.nextcloud, "Nextcloud", systemImage: LibrarySource.nextcloud.symbolName,
                        value: appModel.hasNextcloudServer ? host(appModel.nextcloudServerURL) : "Not Set")
                    row(.photoLibrary, "Photo Library", systemImage: LibrarySource.photos.symbolName,
                        value: PhotoLibrarySection.statusLabel)
                    row(.localFiles, "Local Files", systemImage: LibrarySource.local.symbolName)
                    #if HYPNOS_YOUTUBE
                    if youTubeOn {
                        row(.youtube, "YouTube", systemImage: "play.rectangle")
                    }
                    #endif
                }

                Section {
                    row(.deviceSetup, "Device Setup", systemImage: "qrcode")
                } footer: {
                    Text("Send your servers and sign-ins to another device, or set this one up from another.")
                }

                Section("Viewing") {
                    row(.general, "General", systemImage: "gearshape")
                    row(.gallery, "Gallery", systemImage: "square.grid.3x3")
                    row(.photos, "Photos", systemImage: "photo")
                    row(.videos, "Videos", systemImage: "play.rectangle.on.rectangle")
                    row(.slideshows, "Slideshows", systemImage: "play.square.stack")
                    if PlatformCapabilities.supportsWindowManagement {
                        row(.windowGroups, "Window Groups", systemImage: "macwindow.on.rectangle",
                            value: appModel.savedWindowGroups.isEmpty ? "" : "\(appModel.savedWindowGroups.count)")
                    }
                }

                if PlatformCapabilities.supportsStereoVideo {
                    Section {
                        row(.ai3D, "AI 3D", systemImage: "cube", value: AI3DSettingsPage.statusLabel)
                    }
                }

                Section {
                    row(.cache, "Cache", systemImage: "internaldrive", value: cachePreset.label)
                    row(.backup, "Backup", systemImage: "externaldrive")
                }

                Section {
                    row(.developer, "Developer", systemImage: "hammer")
                }

                Section {
                    LabeledContent("Version", value: appVersionString)
                    Button("Show Welcome Screen Again") {
                        appModel.hasCompletedWelcome = false
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .moreTabBackButton()
            .navigationDestination(for: Page.self, destination: page)
            .onAppear { cachePreset = CacheBudget.preset }
        }
    }

    private func row(_ page: Page, _ title: String, systemImage: String, value: String = "") -> some View {
        NavigationLink(value: page) {
            LabeledContent {
                Text(value)
            } label: {
                Label(title, systemImage: systemImage)
            }
        }
    }

    @ViewBuilder
    private func page(_ page: Page) -> some View {
        switch page {
        case .jellyfin: SettingsPage("Jellyfin") { JellyfinServerSection() }
        case .stash: SettingsPage("Stash") { StashServerSection() }
        case .nextcloud: SettingsPage("Nextcloud") { NextcloudSettingsSection() }
        case .photoLibrary: SettingsPage("Photo Library") { PhotoLibrarySection() }
        case .localFiles: SettingsPage("Local Files") { LocalFilesSection() }
        #if HYPNOS_YOUTUBE
        case .youtube: SettingsPage("YouTube") { YouTubeSettingsSection() }
        #endif
        case .deviceSetup:
            // Never shown on tvOS (`TVSettingsView`), which can't send.
            #if os(tvOS)
            DeviceSetupReceiveView()
            #else
            DeviceSetupSettingsPage()
            #endif
        case .general: GeneralSettingsPage()
        case .gallery: GallerySettingsPage()
        case .photos: PhotoSettingsPage()
        case .videos: VideoSettingsPage()
        case .ai3D: AI3DSettingsPage()
        case .slideshows: SlideshowSettingsPage()
        case .windowGroups: WindowGroupsSettingsPage()
        case .cache: SettingsPage("Cache") { CacheSettingsSection() }
        case .backup:
            #if os(tvOS)
            EmptyView()
            #else
            BackupSettingsPage()
            #endif
        case .developer: DeveloperSettingsPage()
        }
    }

    private var jellyfinStatus: String {
        if let user = jellyfin.session { return user.userName }
        return film.server.isEmpty ? "Not Set" : host(film.server)
    }

    private func host(_ url: String) -> String {
        URL(string: url)?.host ?? url
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
