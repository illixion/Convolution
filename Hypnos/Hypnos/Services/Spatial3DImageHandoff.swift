/*
 Hypnos - Spatial 3D Image Handoff

 In-memory, refcounted handoff of a generated `ImagePresentationComponent.Spatial3DImage`
 between photo windows, so popping a 3D image out of the gallery reuses the already
 generated instance instead of decoding and regenerating from bytes.

 `Spatial3DImage` is a class and `generate()` mutates it in place, so the generated
 state travels with the reference. `PhotoWindowValue` being Codable is irrelevant here
 — it is only an identity token for visionOS; the payload rides in memory, exactly as
 `SharedTextureCache` already does for the 2D MTLTexture.

 Confirmed on device (Apple Vision Pro, visionOS 26.5, 2026-08-24): one instance may
 back two *live* components in two different scenes. The generated state travels with
 the reference (`supportedViewingModes` still reports spatial3D/spatial3DImmersive after
 the crossing, `aspectRatio(for: .spatial3D)` resolves on the second component, and the
 second presents with a non-zero `presentationScreenSize`) with no regeneration, no
 RealityKit error and no crash. `claim` is therefore refcounted rather than a move, so
 "Open Copy" can share one instance between two windows that both stay open.
 */

import DebugTrace
import Foundation
import RealityKit

@MainActor
final class Spatial3DImageHandoff {
    static let shared = Spatial3DImageHandoff()

    struct Key: Hashable {
        let imageURL: String
        /// The spatial-3D source cap the instance was generated at.
        /// Per-window (`spatial3DResolutionOverride`), so it is part of identity.
        let sourceDimension: Int

        /// `imageURL` with credential query values redacted, for logs.
        var loggableImageURL: String {
            URL(string: imageURL)?.loggableDescription ?? "<unparseable URL>"
        }
    }

    private struct Entry {
        let image: ImagePresentationComponent.Spatial3DImage
        let aspectRatio: CGFloat?
        /// Viewing mode the depositing window was in, so the receiving window
        /// opens in the same mode rather than dropping immersive to windowed 3D.
        let viewingMode: ImagePresentationComponent.ViewingMode
        /// Live claimers.
        var refCount: Int
        /// Held by the registry itself between the deposit and the first claim.
        /// Without it the depositing window's `cleanup()` — which fires as soon
        /// as `dismissWindow()` tears the source scene down, and races the new
        /// window's open — would drop the last reference and evict the deposit
        /// before anyone could pick it up.
        var graceTask: Task<Void, Never>?
    }

    /// How long an unclaimed deposit is kept. Long enough to cover a window
    /// open (observed at ~2ms on device), short enough that an abandoned
    /// deposit cannot pin a generated scene's GPU memory for any real time.
    private static let graceInterval: Duration = .seconds(30)

    private var entries: [Key: Entry] = [:]

    /// Deposit a *generated* instance for another window to pick up.
    ///
    /// The depositing window keeps its own strong reference through its
    /// `spatial3DImage` property, so it deliberately does *not* take a
    /// registry reference — the registry holds a grace reference instead, and
    /// the entry outlives the source window's teardown either way.
    func deposit(
        key: Key,
        image: ImagePresentationComponent.Spatial3DImage,
        aspectRatio: CGFloat?,
        viewingMode: ImagePresentationComponent.ViewingMode
    ) {
        // A re-deposit replaces the entry: the newest generated instance is
        // the one the next window should get. Existing claimers are unaffected
        // — they hold the instance itself, not the registry slot.
        entries[key]?.graceTask?.cancel()
        entries[key] = Entry(
            image: image,
            aspectRatio: aspectRatio,
            viewingMode: viewingMode,
            refCount: 0,
            graceTask: nil
        )
        entries[key]?.graceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.graceInterval)
            guard !Task.isCancelled else { return }
            self?.expireGrace(key: key)
        }
        AppLogger.photoWindow.debug(
            "[Handoff] deposit key=\(key.loggableImageURL, privacy: .private(mask: .hash))@\(key.sourceDimension, privacy: .public)"
        )
    }

    /// The grace window elapsed with nobody claiming — drop the deposit.
    private func expireGrace(key: Key) {
        guard var entry = entries[key] else { return }
        entry.graceTask = nil
        if entry.refCount <= 0 {
            entries.removeValue(forKey: key)
            AppLogger.photoWindow.debug(
                "[Handoff] deposit expired unclaimed key=\(key.loggableImageURL, privacy: .private(mask: .hash))@\(key.sourceDimension, privacy: .public)"
            )
        } else {
            entries[key] = entry
        }
    }

    /// Take a reference to a deposited instance, incrementing its refcount.
    func claim(key: Key) -> (
        image: ImagePresentationComponent.Spatial3DImage,
        aspectRatio: CGFloat?,
        viewingMode: ImagePresentationComponent.ViewingMode
    )? {
        guard var entry = entries[key] else { return nil }
        entry.refCount += 1
        // First claimer takes over from the registry's grace reference.
        entry.graceTask?.cancel()
        entry.graceTask = nil
        entries[key] = entry
        AppLogger.photoWindow.debug(
            "[Handoff] claim HIT refCount=\(entry.refCount, privacy: .public) key=\(key.loggableImageURL, privacy: .private(mask: .hash))@\(key.sourceDimension, privacy: .public)"
        )
        return (entry.image, entry.aspectRatio, entry.viewingMode)
    }

    /// Release one reference; the instance is dropped when the last holder leaves.
    func release(key: Key) {
        guard var entry = entries[key] else { return }
        entry.refCount -= 1
        // Evicting the slot does not free the instance — a window that is still
        // showing it owns it through its own `spatial3DImage`. The registry is a
        // handoff channel, not the owner.
        if entry.refCount <= 0 && entry.graceTask == nil {
            entries.removeValue(forKey: key)
        } else {
            entries[key] = entry
        }
    }

    /// Drop everything — memory-pressure hook.
    func evictAll() {
        guard !entries.isEmpty else { return }
        AppLogger.photoWindow.info("[Handoff] evictAll count=\(self.entries.count, privacy: .public)")
        for entry in entries.values { entry.graceTask?.cancel() }
        entries.removeAll()
    }

    /// Non-retaining existence check — used to decide whether a window opening
    /// should go straight into 3D mode because a generated instance is waiting.
    func has(key: Key) -> Bool { entries[key] != nil }
}
