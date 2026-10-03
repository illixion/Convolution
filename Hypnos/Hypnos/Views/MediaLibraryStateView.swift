/*
 Hypnos - Media Library State Views

 The screens shown in place of a grid when there is nothing to draw, shared by
 the Pictures and Videos tabs so both read as one family.

 Three photo-library states need saying out loud, and which of them carries an
 action is the whole point:

   * Undecided — offers the prompt, because the user has not been asked yet.
   * Denied or restricted — sends them to Settings, the only place it can change.
   * Readable but empty — NO action, because there is nothing to fix. A
     `.limited` grant with nothing selected is a legitimate choice, not a
     failure, and offering a button there implies the user did something wrong.

 A fourth state is not about permission at all: readable, non-empty, but the
 active filter matches nothing. That one *does* carry an action, because the
 cause is something the user set and can unset — and without it a filtered-out
 library is indistinguishable from an empty one, which reads as the app having
 lost the photos.
 */

import Photos
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import Foundation
import ImageIO

/// The shared shape. Every state below is this with different words, which is
/// what keeps them recognisable as the same kind of message.
///
/// `secondaryActions` is where `LibrarySafetyNetView` slots in below the
/// primary button — nested inside this view's own centered `VStack` rather
/// than placed alongside it, because this view already claims the full
/// available height (`.frame(maxHeight: .infinity)`); a sibling added
/// outside it would be squeezed off-screen instead of appearing under the
/// message.
struct MediaLibraryMessageView<SecondaryActions: View>: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
    @ViewBuilder var secondaryActions: () -> SecondaryActions

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            Text(title)
                .font(.title2)
            Text(message)
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
            secondaryActions()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Every existing call site predates `secondaryActions` and passes none, so
/// this is what lets them keep compiling unchanged.
extension MediaLibraryMessageView where SecondaryActions == EmptyView {
    init(icon: String, title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        self.secondaryActions = { EmptyView() }
    }
}

/// Explains the photo library's current state for one media kind.
struct PhotoLibraryStateView: View {
    enum MediaKind {
        case photos
        case videos

        var noun: String { self == .photos ? "photos" : "videos" }
        var emptyIcon: String { self == .photos ? "photo.on.rectangle.angled" : "video.slash" }
    }

    let kind: MediaKind
    let status: PHAuthorizationStatus
    /// Whether a photo-library filter is narrowing the results.
    var filterActive: Bool = false
    var onClearFilters: (() -> Void)?
    /// Progress text while the library is being indexed, or nil.
    ///
    /// Takes precedence over both empty states: a library mid-scan genuinely has
    /// nothing to show yet, and saying "no photos" about it is wrong in the way
    /// that makes people re-grant permissions that were never the problem.
    var indexingMessage: String?
    let onRequestAccess: () -> Void

    @Environment(\.openURL) private var openURL

    var body: some View {
        if let indexingMessage, PhotosAuthorization.isReadable(status) {
            MediaLibraryMessageView(
                icon: "hourglass",
                title: "Indexing Your Library",
                message: indexingMessage
            )
        } else {
            authorizationState
        }
    }

    @ViewBuilder
    private var authorizationState: some View {
        switch status {
        case .notDetermined:
            MediaLibraryMessageView(
                icon: "photo.on.rectangle.angled",
                title: "Show Your \(kind == .photos ? "Photos" : "Videos")?",
                // Only Vision Pro converts to 3D; on iOS the promise is
                // browsing, slideshows and enhancements.
                message: PlatformCapabilities.supportsSpatial3D
                    ? "Convolution can browse the \(kind.noun) on this device and convert them to 3D. Your library is read on this device only — nothing is uploaded."
                    : "Convolution can browse the \(kind.noun) on this device. Your library is read on this device only — nothing is uploaded.",
                actionTitle: "Allow Access to Photos",
                action: onRequestAccess
            ) {
                // This state's own primary button already covers Photos, so
                // the net only has something new to offer if it also names a
                // media server — Local needs no permission, so it never adds
                // anything not already implied by "no server yet".
                LibrarySafetyNetView(offersPhotosAccess: false)
            }
        case .denied, .restricted:
            MediaLibraryMessageView(
                icon: "lock.fill",
                title: "Photo Access Denied",
                message: "Convolution can't see your photo library. Allow access in Settings to browse and convert your \(kind.noun), or connect a media server instead.",
                actionTitle: "Open Settings",
                action: {
                    #if os(macOS)
                    // No per-app Settings deep link on macOS (this button
                    // belongs to the visionOS/iOS Photos permission screen,
                    // which the Mac UI doesn't use — see Hypnos/CLAUDE.md
                    // "macOS"). Open System Settings generally rather than
                    // do nothing.
                    guard let url = URL(string: "x-apple.systempreferences:") else { return }
                    #else
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    #endif
                    openURL(url)
                }
            ) {
                LibrarySafetyNetView(offersPhotosAccess: false)
            }
        case .limited where !filterActive:
            // No action: the user chose a set, and it contains none of this
            // media kind. That is a valid outcome, so the message says where to
            // widen the selection without framing it as an error.
            MediaLibraryMessageView(
                icon: kind.emptyIcon,
                title: "No \(kind == .photos ? "Photos" : "Videos") to Show",
                message: "Convolution can only see the items you selected, and none of them are \(kind.noun). Choose more in Settings › Privacy & Security › Photos."
            ) {
                LibrarySafetyNetView(offersPhotosAccess: false)
            }
        default:
            if filterActive {
                MediaLibraryMessageView(
                    icon: "line.3.horizontal.decrease.circle",
                    title: "No Matches",
                    message: "No \(kind.noun) in this library match the current filter.",
                    actionTitle: onClearFilters == nil ? nil : "Clear Filters",
                    action: onClearFilters
                )
            } else {
                MediaLibraryMessageView(
                    icon: kind.emptyIcon,
                    title: "No \(kind == .photos ? "Photos" : "Videos") to Show",
                    message: "There are no \(kind.noun) in this library yet."
                ) {
                    LibrarySafetyNetView(offersPhotosAccess: false)
                }
            }
        }
    }
}

// MARK: - Safety net

/// Inline ways to add another source when the current one has nothing to
/// show — so anyone who skipped every option in first run, or whose one
/// configured source has just gone quiet, can still get to Photos access or
/// a media server connection from wherever they land empty, with no trip to
/// Settings. Suppresses whichever half is already satisfied or already
/// covered by the message above it, so it never doubles up on an offer.
///
/// The server form mirrors `WelcomeSourcesPage.serverForm`'s validation flow
/// (kept separate rather than shared, since that one is wired into a whole
/// first-run page's `onSourceConfigured` callback and local draft state that
/// don't apply here).
struct LibrarySafetyNetView: View {
    @Environment(AppModel.self) private var appModel

    /// False when the message above already offers (or explains why it
    /// can't offer) a way to fix the Photos side specifically, so this would
    /// only repeat it.
    var offersPhotosAccess: Bool = true

    @State private var isRequestingPhotos = false
    @State private var isServerExpanded = false
    @State private var draftServerURL = ""
    @State private var draftAPIKey = ""
    @State private var serverState = ServerState.idle

    private enum ServerState: Equatable {
        case idle
        case connecting
        case connected(Int)
        case failed(String)
    }

    private var showsPhotosOption: Bool {
        offersPhotosAccess && !PhotosAuthorization.isReadable(PhotosAuthorization.status)
    }

    private var showsServerOption: Bool {
        !appModel.hasStashServer
    }

    var body: some View {
        if showsPhotosOption || showsServerOption {
            VStack(spacing: 14) {
                Text("Add Another Source")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    if showsPhotosOption {
                        Button {
                            Task {
                                isRequestingPhotos = true
                                await appModel.requestPhotosAccessAndReload()
                                isRequestingPhotos = false
                            }
                        } label: {
                            if isRequestingPhotos {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Allow Photos Access", systemImage: "photo.on.rectangle.angled")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isRequestingPhotos)
                    }

                    if showsServerOption && !isServerExpanded {
                        Button {
                            isServerExpanded = true
                        } label: {
                            Label("Connect a Media Server", systemImage: "server.rack")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if showsServerOption && isServerExpanded {
                    serverForm
                }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var serverForm: some View {
        VStack(spacing: 10) {
            TextField("http://stash.local:9999", text: $draftServerURL)
                .roundedTextFieldStyle()
                .textContentType(.URL)
                .autocorrectionDisabled()
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                #endif
                #if !os(macOS)
                .keyboardType(.URL)
                #endif
                .onSubmit { Task { await connect() } }

            SecureField("API key (optional)", text: $draftAPIKey)
                .roundedTextFieldStyle()
                .autocorrectionDisabled()
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { Task { await connect() } }

            HStack(spacing: 12) {
                Button {
                    Task { await connect() }
                } label: {
                    if serverState == .connecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Connect")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(serverState == .connecting
                          || draftServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                switch serverState {
                case .connected(let count):
                    Label("Connected — \(count) item\(count == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                case .failed(let message):
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                case .idle, .connecting:
                    EmptyView()
                }
            }
        }
        .frame(maxWidth: 360)
    }

    private func connect() async {
        serverState = .connecting
        do {
            let count = try await appModel.verifyStashServer(url: draftServerURL, apiKey: draftAPIKey)
            appModel.commitStashServer(url: draftServerURL, apiKey: draftAPIKey)
            serverState = .connected(count)
        } catch {
            serverState = .failed(error.localizedDescription)
        }
    }
}
