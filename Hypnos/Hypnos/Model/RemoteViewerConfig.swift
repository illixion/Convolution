/*
 Hypnos - Remote Viewer Configuration

 A slideshow window's display settings. There are two profiles, one for
 picture slideshows and one for video slideshows, persisted to UserDefaults
 by AppModel, so ornament tweaks carry over to the next slideshow.
 */

import Foundation
import RAVESlideshow

/// Per-slideshow 3D rendering mode. In the RealityKit modes each image is
/// loaded into a RealityKit `ImagePresentationComponent` instead of a 2D
/// SwiftUI `Image`; in AI 3D a depth mesh is laid over the 2D image. Any 3D
/// mode bypasses Ken Burns + Diorama (the 3D geometry doesn't follow the
/// SwiftUI transforms).
enum Slideshow3DMode: String, Codable, CaseIterable, Identifiable {
    case off
    case spatial3D
    case immersive3D
    /// Pictures as a depth-displaced mesh from the real-time depth model
    /// (`RAVEAIDepthPhotoView`). Videos convert in real time in every 3D mode.
    case aiDepth

    var id: String { rawValue }
    /// Menu names. The raw values predate them and stay: they're persisted.
    var label: String {
        switch self {
        case .off: return "2D"
        case .spatial3D: return "RealityKit 3D"
        case .immersive3D: return "RealityKit 3D (Immersive)"
        case .aiDepth: return "AI 3D"
        }
    }
    /// The short form, for the ornament button's tooltip.
    var shortLabel: String {
        switch self {
        case .off: return "2D"
        case .spatial3D: return "RK 3D"
        case .immersive3D: return "RK 3D (Immersive)"
        case .aiDepth: return "AI 3D"
        }
    }
    /// Pictures go through RealityKit's `ImagePresentationComponent`.
    var usesRealityKit: Bool { self == .spatial3D || self == .immersive3D }
    /// What the shared slideshow engine is told: AI 3D textures a mesh from
    /// the 2D-sized picture, so it takes the 2D resolution cap.
    var raveMode: RAVESlideshow3DMode {
        switch self {
        case .off, .aiDepth: return .off
        case .spatial3D: return .spatial3D
        case .immersive3D: return .immersive3D
        }
    }
    var systemImage: String {
        // Match the icons used by the regular picture viewer's 3D menu so
        // the slideshow ornament is visually consistent.
        switch self {
        case .off: return "view.3d"
        case .spatial3D: return "spatial.capture.fill"
        case .immersive3D: return "inset.filled.pano"
        case .aiDepth: return "wand.and.sparkles"
        }
    }
}

/// `Equatable` lets AppModel skip persisting a write-back that changed
/// nothing. Every stored property is value-typed, so the synthesized `==` is
/// the whole comparison.
struct RemoteViewerConfig: Codable, Identifiable, Equatable {
    private(set) var id: UUID
    var name: String
    private(set) var savedDate: Date

    // Display
    var delay: TimeInterval = 15
    var showClock: Bool = true
    var useAspectRatio: Bool = true
    var enableKenBurns: Bool = true
    var enableDynamicBrightness: Bool = true
    var enableDiorama: Bool = false
    var transparentBackground: Bool = false
    var textSize: Double = 1.0

    /// Slideshow 3D rendering mode. `.off` uses the regular 2D SwiftUI image
    /// pipeline. `.spatial3D`/`.immersive3D` load each image into a RealityKit
    /// `ImagePresentationComponent` and override Ken Burns + Diorama.
    var slideshow3DMode: Slideshow3DMode = .off

    /// Per-profile cap for the 2D slideshow image pipeline. `nil` = inherit
    /// `AppModel.slideshowMaxImageResolution2D`.
    var maxImageResolution2D: Int?

    /// Per-profile cap fed into RealityKit when slideshow 3D is enabled.
    /// `nil` = inherit `AppModel.slideshowMaxImageResolution3D`.
    var maxImageResolution3D: Int?

    init(name: String) {
        self.id = UUID()
        self.name = name
        self.savedDate = Date()
    }

    /// Overwrite exactly the fields an open slideshow window can change from
    /// its ornament and adjustments panel, leaving everything else alone.
    ///
    /// A window holds the profile as it was when it opened, so persisting that
    /// snapshot wholesale would revert what another window of the same profile
    /// changed in the meantime. The window's write-back merges through here
    /// instead. Keep this list in sync with the `display*` setters on
    /// `RemoteViewerModel` plus the ornament's 3D-mode and resolution menus.
    mutating func applyViewerDisplaySettings(from source: RemoteViewerConfig) {
        delay = source.delay
        showClock = source.showClock
        useAspectRatio = source.useAspectRatio
        enableKenBurns = source.enableKenBurns
        enableDynamicBrightness = source.enableDynamicBrightness
        enableDiorama = source.enableDiorama
        transparentBackground = source.transparentBackground
        slideshow3DMode = source.slideshow3DMode
        maxImageResolution2D = source.maxImageResolution2D
        maxImageResolution3D = source.maxImageResolution3D
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, savedDate
        case delay, showClock, useAspectRatio, enableKenBurns
        case enableDynamicBrightness, enableDiorama
        case transparentBackground, textSize
        case slideshow3DMode, maxImageResolution2D, maxImageResolution3D
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        savedDate = try container.decode(Date.self, forKey: .savedDate)

        delay = try container.decodeIfPresent(TimeInterval.self, forKey: .delay) ?? 15
        showClock = try container.decodeIfPresent(Bool.self, forKey: .showClock) ?? true
        useAspectRatio = try container.decodeIfPresent(Bool.self, forKey: .useAspectRatio) ?? true
        enableKenBurns = try container.decodeIfPresent(Bool.self, forKey: .enableKenBurns) ?? true
        enableDynamicBrightness = try container.decodeIfPresent(Bool.self, forKey: .enableDynamicBrightness) ?? true
        enableDiorama = try container.decodeIfPresent(Bool.self, forKey: .enableDiorama) ?? false
        transparentBackground = try container.decodeIfPresent(Bool.self, forKey: .transparentBackground) ?? false
        textSize = try container.decodeIfPresent(Double.self, forKey: .textSize) ?? 1.0
        slideshow3DMode = try container.decodeIfPresent(Slideshow3DMode.self, forKey: .slideshow3DMode) ?? .off
        maxImageResolution2D = try container.decodeIfPresent(Int.self, forKey: .maxImageResolution2D)
        maxImageResolution3D = try container.decodeIfPresent(Int.self, forKey: .maxImageResolution3D)
    }
}
