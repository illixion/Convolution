/*
 Hypnos - Library feature: telling the user how to get Skip Intro

 `SkipMarkersSection` sits under Settings → Jellyfin on every platform and
 walks an administrator through `IntroSkipperSetup`: install, restart,
 analyse. Each server action asks first, and the install's confirmation says
 the server will download from outside (the Intro Skipper repository and
 GitHub). Other accounts get the steps to pass on to whoever runs the server.

 `SkipMarkersHint` is the same offer where it's noticed: on a series' page
 when the episode Play would start has no markers. "Don't Show Again" is for
 good; Settings still has the section.
 */

import SwiftUI

struct SkipMarkersSection: View {
    /// Off where the screen's own title already says "Skip Intro".
    var showsHeader = true
    private let setup = IntroSkipperSetup.shared
    @State private var confirmingInstall = false
    @State private var confirmingRestart = false

    var body: some View {
        if LibraryService.isAvailable {
            Section {
                rows
                if let error = setup.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                if showsHeader { Text("Skip Intro") }
            } footer: {
                Text("Skip Intro and Skip Credits need markers from the server, and Jellyfin makes none by itself. Without a plugin, only files whose chapters are named Intro or Credits have them.")
            }
            .task(id: LibraryService.configurationKey) { await setup.refresh(force: true) }
            .task(id: setup.analysis?.isRunning == true) {
                while setup.analysis?.isRunning == true, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    await setup.refreshAnalysis()
                }
            }
            .alert("Install Intro Skipper?", isPresented: $confirmingInstall) {
                Button("Install") { Task { await setup.install() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your Jellyfin server at \(serverHost) will add the Intro Skipper plugin repository (intro-skipper.org) and download the plugin from GitHub. Convolution itself only talks to your server.\n\nThe server then needs a restart, and analyzes your episodes' audio in the background, which takes a while on a large library.")
            }
            .alert("Restart Jellyfin?", isPresented: $confirmingRestart) {
                Button("Restart", role: .destructive) { Task { await setup.restartServer() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The server at \(serverHost) restarts to load Intro Skipper. Anyone watching from it is interrupted for about a minute.")
            }
        }
    }

    @ViewBuilder
    private var rows: some View {
        switch setup.status {
        case .unknown:
            if setup.isChecking {
                Label("Checking the server's plugins…", systemImage: "hourglass")
            } else {
                Label("Couldn't check the server's plugins", systemImage: "questionmark.circle")
                Button("Check Again") { Task { await setup.refresh(force: true) } }
            }
        case .notAdmin:
            Label("Intro Skipper can't be checked from this account", systemImage: "person.badge.key")
            Text("Only a server administrator can install plugins. In Jellyfin's Dashboard → Plugins → Repositories, add \(IntroSkipperSetup.repositoryURL), then install Intro Skipper from the catalog and restart the server.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .missing:
            Label("Intro Skipper isn't installed", systemImage: "exclamationmark.circle")
                .foregroundStyle(.orange)
            Text("This server plugin finds intros and credits by comparing the audio of a season's episodes, so every show gets a skip button.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if setup.work == .installing {
                ProgressView("Installing…")
            } else {
                Button("Install on the Server…") { confirmingInstall = true }
            }
        case .needsRestart:
            Label("Installed: the server needs a restart", systemImage: "arrow.clockwise.circle")
                .foregroundStyle(.orange)
            if setup.work == .restarting {
                ProgressView("Restarting the server…")
            } else {
                Button("Restart the Server…") { confirmingRestart = true }
            }
        case .active:
            Label("Intro Skipper is installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            analysisRows
        case .inactive(let reason):
            Label("Intro Skipper is installed but not running (\(reason))", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text("Check it under Dashboard → Plugins on the server.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var analysisRows: some View {
        if let analysis = setup.analysis, analysis.isRunning {
            if let progress = analysis.progress {
                ProgressView("Analyzing episodes…", value: progress)
            } else {
                ProgressView("Analyzing episodes…")
            }
        } else {
            Button("Analyze Episodes Now") { Task { await setup.startAnalysis() } }
                .disabled(setup.work != nil)
            Text(analysisCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var analysisCaption: String {
        let schedule = "It also runs every night and picks up new episodes by itself."
        guard let lastRun = setup.analysis?.lastRun else { return "Not run yet. " + schedule }
        return "Last run \(lastRun.formatted(.relative(presentation: .named))). " + schedule
    }

    private var serverHost: String {
        URL(string: FilmSession.shared.server)?.host ?? FilmSession.shared.server
    }
}

/// The offer on a series' page; shown only when
/// `IntroSkipperSetup.suggestsInstall(for:)` said so. "Set Up…" asks the page
/// for `skipMarkersSetupSheet`, hung on the page's root: presented from in
/// here, the sheet would inherit the white tint the page gives its content
/// over artwork, and no `.tint` inside the sheet undoes that.
struct SkipMarkersHint: View {
    let onSetUp: () -> Void
    let onDismiss: () -> Void
    private let setup = IntroSkipperSetup.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "forward.end.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("No Skip Intro for this show").font(.headline)
                Text(setup.status == .notAdmin
                     ? "Jellyfin has no intro markers for it. Ask whoever runs your server about the Intro Skipper plugin."
                     : "Jellyfin has no intro markers for it. The Intro Skipper plugin on your server can find them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Set Up…", action: onSetUp)
                    Button("Don't Show Again") {
                        UserDefaults.standard.set(true, forKey: IntroSkipperSetup.hintDismissedKey)
                        onDismiss()
                    }
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: 640, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

extension View {
    /// The setup screen `SkipMarkersHint` opens; `onClose` hears whether
    /// the hint still applies (the plugin may be in by then).
    func skipMarkersSetupSheet(isPresented: Binding<Bool>, onClose: @escaping (_ stillSuggested: Bool) -> Void) -> some View {
        sheet(isPresented: isPresented, onDismiss: { onClose(IntroSkipperSetup.shared.suggestsInstall) }) {
            SkipMarkersSetupSheet()
        }
    }
}

private struct SkipMarkersSetupSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form { SkipMarkersSection(showsHeader: false) }
                #if os(macOS)
                .formStyle(.grouped)
                #endif
                .navigationTitle("Skip Intro")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 360)
        #endif
    }
}
