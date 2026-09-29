/*
 Hypnos - Welcome Sample

 Resolves the bundled sample photo that the welcome flow converts to 3D.

 It has to be a **file URL**, not a `UIImage`, because that is what
 `ImagePresentationComponent.Spatial3DImage(contentsOf:)` takes — the welcome
 screen runs the real conversion pipeline rather than showing a canned
 before/after, and the real pipeline reads bytes off disk. An asset-catalog
 entry has no URL, so one dropped in that way is re-encoded into the caches
 directory once and served from there.

 Two ways to supply the sample, both looked for here:

   1. A resource file named `WelcomeSample.heic` (or .jpg/.png) anywhere in the
      app target. Preferred — nothing is re-encoded, and a HEIC that already
      carries a depth map converts faster and better.
   2. An asset-catalog image set named `WelcomeSample`.

 With neither present the welcome screen still works: it shows an explanatory
 card in place of the photo and hides the 3D control, which is why every entry
 point here returns an optional rather than trapping. A missing sample must
 degrade the first screen, never break the flow that follows it.
 */

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import DebugTrace
import Foundation
import ImageIO

@MainActor
enum WelcomeSample {

    /// Resource / asset name, in both lookup forms.
    static let name = "WelcomeSample"

    /// Extensions tried as a bundled resource file, best first.
    private static let fileExtensions = ["heic", "heif", "jpg", "jpeg", "png"]

    /// Memoized answer, including a memoized *absence*. The nested optional is
    /// the point: `.some(nil)` means "looked, nothing bundled".
    private static var resolved: URL??

    /// The sample's file URL, or nil when no sample is bundled.
    static func url() -> URL? {
        if let resolved { return resolved }
        let found = locate()
        resolved = .some(found)
        if found == nil {
            AppLogger.settings.info("Welcome sample not bundled — intro screen will show the fallback card")
        }
        return found
    }

    /// Whether a sample exists at all, for views deciding what to draw.
    static var isAvailable: Bool { url() != nil }

    private static func locate() -> URL? {
        for ext in fileExtensions {
            if let url = Bundle.main.url(forResource: name, withExtension: ext) {
                return url
            }
        }
        return materializeFromAssetCatalog()
    }

    /// Writes an asset-catalog image out as a file so it has a URL.
    ///
    /// JPEG at high quality rather than HEIC: the asset catalog has already
    /// flattened whatever was imported, so there is no depth map or wide-gamut
    /// precision left to preserve, and JPEG encoding is available everywhere.
    private static func materializeFromAssetCatalog() -> URL? {
        guard let image = UIImage(named: name) else { return nil }
        guard let data = image.jpegData(compressionQuality: 0.95) else { return nil }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name).jpg")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            AppLogger.settings.error("Could not materialize welcome sample: \(error.localizedDescription) (\(error.logCode, privacy: .public))")
            return nil
        }
    }
}
