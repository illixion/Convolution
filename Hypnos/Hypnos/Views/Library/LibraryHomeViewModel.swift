/*
 Hypnos - Library feature: shared home view model

 Loads `MediaServerLibrary.home()` once and exposes it as `@Observable`
 state, so every platform's home screen (tvOS's hero+shelves, visionOS/iOS/
 macOS's own layouts) drives off the same load/refresh/error logic instead
 of each re-implementing it. Platform views differ only in how they lay the
 result out.
 */

import Foundation
import Observation

@MainActor
@Observable
final class LibraryHomeViewModel {
    private(set) var home: LibraryHome?
    private(set) var isLoading = false
    private(set) var error: String?

    /// nil when no server is configured — the caller (the Library tab) is
    /// only ever shown once `LibraryService.current()` is non-nil, but a
    /// sign-out or server change while the tab is open should still degrade
    /// gracefully rather than crash.
    private var library: JellyfinLibrary?

    /// (Re)loads against whatever server and credentials are current. Call
    /// from `.task(id: LibraryService.configurationKey)` so it re-runs when a
    /// sign-in completes or the server changes.
    func start() async {
        let fresh = LibraryService.current()
        if fresh?.baseURL != library?.baseURL { home = nil }
        library = fresh
        await refresh()
    }

    func refresh() async {
        guard let library else {
            error = "No Jellyfin server configured."
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            home = try await library.home()
        } catch is CancellationError {
            // Superseded by a newer load (configuration changed); not an error.
        } catch let urlError as URLError where urlError.code == .cancelled {
        } catch {
            self.error = error.localizedDescription
        }
    }
}
