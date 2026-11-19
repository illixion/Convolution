//
//  HypnosSceneID.swift
//  Hypnos
//
//  Scene ids. Standalone they are the bare names ("main"), spelled as they always were because
//  visionOS restores open windows by them. Built into Nexus (`NEXUS_MODULE`), which runs this
//  app beside others as a module of one process, each carries the module's prefix: the other
//  modules have windows called "main" too, a process has one namespace of scene ids, and RAVEUI's
//  window helpers scope a module's windows by that prefix. See docs/nexus-module.md.
//
//  Every `openWindow(id:)`, `pushWindow`, `dismissWindow` and scene declaration goes through
//  these, never a string literal.
//

import Foundation

enum HypnosSceneID {
    #if NEXUS_MODULE
    static let prefix = "hypnos."
    #else
    static let prefix = ""
    #endif

    static func id(_ name: String) -> String { prefix + name }

    static let main = id("main")
    static let photoDetail = id("photo-detail")
    static let videoDetail = id("video-detail")
    static let sharedPhoto = id("shared-photo")
    static let console = id("console")
    static let gpuMemory = id("gpu-memory")
    static let videoAdjustments = id("video-adjustments")
    static let video3DPanel = id("video-3d-panel")
    static let remoteViewer = id("remote-viewer")
    #if HYPNOS_GEN3D
    static let gen3d = id("gen3d")
    static let gen3dLibrary = id("gen3d-library")
    #endif
}
