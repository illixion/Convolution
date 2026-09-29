/*
 Hypnos - Window Size Persistence

 Remembers a pop-out window's user-chosen size across cold relaunches and
 re-asserts it when visionOS restores the window at the scene `.defaultSize`.

 Extracted from RemoteViewerWindowView so the pinned web-page window gets the
 same behaviour (both are wall-snapped, long-lived windows whose size the user
 tunes once and expects to stick). Every guard here exists because of a real
 failure — see the comments before loosening any of them.
 */

import DebugTrace
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif
import Foundation

@MainActor
final class WindowSizePersistence {
    /// Smallest geometry a window is allowed to occupy, and the floor below
    /// which a persisted size is treated as corrupt rather than restored.
    static let defaultMinimumSize = CGSize(width: 480, height: 320)

    /// Whether a size is one the user could plausibly have resized to, as
    /// opposed to transient layout noise from a window the compositor hasn't
    /// placed yet. Guards both ends of the persist/restore round-trip.
    static func isPlausible(_ size: CGSize, minimum: CGSize = defaultMinimumSize) -> Bool {
        size.width >= minimum.width && size.height >= minimum.height
            && size.width.isFinite && size.height.isFinite
    }

    private let windowId: UUID
    private let minimumSize: CGSize
    private let log: DebugLogger

    /// Live content size, pushed in by the host view's geometry observer. Used
    /// to verify a restore request actually landed.
    var currentSize: CGSize = .zero

    /// Writes the settled size into the Codable window value so visionOS
    /// persists it in the scene-restoration archive.
    var onSizeSettled: ((CGSize) -> Void)?

    /// Resolves **this** window's scene. Must never fall back to the
    /// foreground-active scene: during cold launch that can be a different
    /// window, which would then receive our resize.
    var windowScene: (() -> PlatformWindowScene?)?

    private var writebackTask: Task<Void, Never>?
    private var suppressTask: Task<Void, Never>?
    private var suppressWriteback = false

    init(
        windowId: UUID,
        minimumSize: CGSize = WindowSizePersistence.defaultMinimumSize,
        log: DebugLogger = AppLogger.windowState
    ) {
        self.windowId = windowId
        self.minimumSize = minimumSize
        self.log = log
    }

    func isPlausible(_ size: CGSize) -> Bool {
        Self.isPlausible(size, minimum: minimumSize)
    }

    /// Apply the persisted custom window size (if any) on launch.
    ///
    /// `requestGeometryUpdate` is routinely ignored while visionOS is still
    /// mid-restoration, and at `onAppear` time this window's scene may not even
    /// be connected yet. So instead of a single fire-and-forget request, retry
    /// until the live geometry actually matches the restored size (within 5%).
    /// Write-back stays suppressed for the duration so the transient
    /// scene-default size isn't persisted over the user's choice.
    ///
    /// - Parameter archived: the size carried by the scene-restoration archive
    ///   (the window value's `restoredSize`), if any.
    func applyRestoredSizeIfNeeded(archived: CGSize?) {
        // Suppress the write-back for the settle period on *every* restored
        // window, before the restored-size guard — not just ones that already
        // have a size persisted. The window that most needs protecting is the
        // one being restored for the first time: it has no archived size, so
        // arming suppression after the guard meant its transient restoration
        // geometry sailed straight into the archive. That is how a window gets
        // poisoned in the first place.
        if RestoredWindowTracker.isRestored(windowId) {
            suppressWriteback = true
            suppressTask?.cancel()
            suppressTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                self?.suppressWriteback = false
            }
        }

        // Prefer the scene-archive value; fall back to the UserDefaults store
        // (written in lockstep) in case the archive round-trip dropped it.
        guard let restored = archived ?? RestoredWindowTracker.windowSize(for: windowId) else { return }
        // Reject a degenerate archived size instead of re-asserting it. An
        // already-poisoned archive heals here: we fall through to the scene
        // default rather than spending 5s forcing the window back to nothing.
        guard isPlausible(restored) else {
            log.warning("[Window \(self.windowId.uuidString, privacy: .public)] ignoring implausible restored size \(Int(restored.width), privacy: .public)x\(Int(restored.height), privacy: .public) — falling back to the scene default")
            RestoredWindowTracker.clearWindowSize(for: windowId)
            return
        }

        suppressWriteback = true
        let source = archived != nil ? "scene archive" : "defaults fallback"
        log.info("[Window \(self.windowId.uuidString, privacy: .public)] applying restored size \(Int(restored.width), privacy: .public)x\(Int(restored.height), privacy: .public) (\(source, privacy: .public))")

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.suppressWriteback = false }
            for attempt in 0..<8 {
                if let scene = self.windowScene?() {
                    WindowGeometry.request(scene, size: restored)
                }
                // Give the OS time to resolve (or ignore) the request, then
                // check the live size reported by the host's geometry observer.
                // That's a content size (insets differ from the scene size), so
                // compare with a tolerance.
                try? await Task.sleep(for: .milliseconds(attempt == 0 ? 400 : 700))
                let current = self.currentSize
                if current.width > 2, current.height > 2,
                   abs(current.width - restored.width) / restored.width < 0.05,
                   abs(current.height - restored.height) / restored.height < 0.05 {
                    return
                }
            }
            log.warning("[Window \(self.windowId.uuidString, privacy: .public)] restored size did not apply after retries (wanted \(Int(restored.width), privacy: .public)x\(Int(restored.height), privacy: .public), have \(Int(self.currentSize.width), privacy: .public)x\(Int(self.currentSize.height), privacy: .public))")
        }
    }

    /// Debounce a write-back of the resolved window size so visionOS persists it
    /// for the next cold relaunch.
    func scheduleWriteback(_ size: CGSize) {
        guard onSizeSettled != nil else { return }
        // The old floor here was `> 2`, which happily persisted the transient
        // geometry a not-yet-placed window reports during restoration. That
        // value then got re-asserted on every subsequent launch, so the window
        // came back invisible until its scene session was destroyed ("Close All
        // Windows"). Only persist a size a user could plausibly have chosen.
        guard !suppressWriteback, isPlausible(size) else { return }
        writebackTask?.cancel()
        writebackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.onSizeSettled?(size)
            // UserDefaults backup in case the scene archive drops the value.
            RestoredWindowTracker.setWindowSize(size, for: self.windowId)
        }
    }

    func cancel() {
        writebackTask?.cancel()
        writebackTask = nil
        suppressTask?.cancel()
        suppressTask = nil
    }
}
