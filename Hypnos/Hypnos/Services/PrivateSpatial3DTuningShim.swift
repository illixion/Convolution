//
//  PrivateSpatial3DTuningShim.swift
//  Hypnos
//
//  Unlike PrivateSpatial3DTuning.swift, this file is always compiled. It gives
//  the spatial-3D paths outside the photo window (slideshow, Quick Look, the
//  immersive fallback) one call to make, so the call sites need no #if and a
//  new path can't silently miss the tuning. Without HYPNOS_PRIVATE_API the body
//  is empty and the call compiles away.
//

import RealityKit

extension ImagePresentationComponent {
    /// Apply the sideload-only private spatial-3D settings if this build has
    /// them. No-op in an App Store build. Call right before `components.set(_:)`.
    @MainActor
    mutating func applyPrivateSpatial3DTuningIfAvailable() {
        #if HYPNOS_PRIVATE_API && os(visionOS)
        PrivateSpatial3DTuningStore.shared.apply(to: &self, rawSplat: false)
        #endif
        // iOS, tvOS, macOS: `ImagePresentationComponent` is the null object from
        // PlatformShims.swift there, so this compiles with nothing to tune.
    }
}
