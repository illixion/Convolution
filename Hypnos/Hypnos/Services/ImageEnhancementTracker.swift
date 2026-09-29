/*
 Hypnos - Image Enhancement Tracker

 Tracks per-image viewing enhancements (spatial 3D conversion, background
 removal) so they can be automatically restored when the image is viewed again.

 Every map here is keyed by `MediaIdentity.persistentKey(for:)`, never by
 `url.absoluteString`. Remote URLs are unaffected (the key is the URL), but a
 local file's absolute URL contains the app container UUID, which visionOS
 changes on every launch — keying on it wrote state that could never be read
 back, so local media silently lost its remembered viewing mode, flip,
 resolution override, window size and adjustments at each launch.
 */

import DebugTrace
import Foundation

enum ViewingModePreference: String {
    case mono
    case spatial3D
    case spatial3DImmersive
    case backgroundRemoved
    case autoEnhanced
    case backgroundRemovedAutoEnhanced
    case diorama
}

actor ImageEnhancementTracker {
    static let shared = ImageEnhancementTracker()

    // UserDefaults keys unchanged for backward compatibility
    private let userDefaultsKey = "spatial3DConvertedImages"
    private let convertedIdentityKey = "spatial3DConvertedIdentities"
    private let lastModeKey = "spatial3DLastViewingMode"
    private let flippedKey = "imageFlippedState"
    private let resolutionOverrideKey = "imageResolutionOverride"
    private let spatial3DResolutionOverrideKey = "imageSpatial3DResolutionOverride"
    private let windowSizeKey = "imageWindowSize"
    private let adjustmentsKey = "imageVisualAdjustments"
    /// Converted images, keyed by URL with the item's *identity* as the value.
    ///
    /// One record, two readings. `wasConverted(url:)` asks the key — the URL is
    /// what a photo window has in hand. The "converted to 3D" filter asks the
    /// values, because a query needs the identity: a Stash image's URL is a
    /// server path with the id buried in it, and recovering the id by parsing
    /// `/image/{id}/` back out would break the first time Stash changed its
    /// paths. Recording it at the one write site that already knows it costs
    /// nothing and cannot go stale.
    private var convertedIdentityByURL: [String: String]
    private var lastViewingModeByURL: [String: String]
    private var flippedByURL: Set<String>
    private var resolutionOverrideByURL: [String: Int]
    private var spatial3DResolutionOverrideByURL: [String: Int]
    private var windowSizeByURL: [String: [Double]]
    private var adjustmentsByURL: [String: Data]

    private init() {
        if let dict = UserDefaults.standard.dictionary(forKey: convertedIdentityKey) as? [String: String] {
            convertedIdentityByURL = dict
        } else if let legacy = UserDefaults.standard.array(forKey: userDefaultsKey) as? [String] {
            // Migrated from the URL-only set. The identity is unknown for these,
            // so the URL key stands in: correct for Photos and local files,
            // where identity *is* the persistent key, and simply absent from the
            // converted filter for older Stash images until they are viewed in
            // 3D again.
            convertedIdentityByURL = Dictionary(uniqueKeysWithValues: legacy.map { ($0, $0) })
        } else {
            convertedIdentityByURL = [:]
        }
        let loadedCount = convertedIdentityByURL.count
        AppLogger.enhancementTracker.info(
            "Loaded \(loadedCount, privacy: .public) previously converted images"
        )

        if let dict = UserDefaults.standard.dictionary(forKey: lastModeKey) as? [String: String] {
            lastViewingModeByURL = dict
        } else {
            lastViewingModeByURL = [:]
        }

        if let saved = UserDefaults.standard.array(forKey: flippedKey) as? [String] {
            flippedByURL = Set(saved)
        } else {
            flippedByURL = []
        }

        if let dict = UserDefaults.standard.dictionary(forKey: resolutionOverrideKey) as? [String: Int] {
            resolutionOverrideByURL = dict
        } else {
            resolutionOverrideByURL = [:]
        }

        if let dict = UserDefaults.standard.dictionary(forKey: spatial3DResolutionOverrideKey) as? [String: Int] {
            spatial3DResolutionOverrideByURL = dict
        } else {
            spatial3DResolutionOverrideByURL = [:]
        }

        if let dict = UserDefaults.standard.dictionary(forKey: windowSizeKey) as? [String: [Double]] {
            windowSizeByURL = dict
        } else {
            windowSizeByURL = [:]
        }

        if let dict = UserDefaults.standard.dictionary(forKey: adjustmentsKey) as? [String: Data] {
            adjustmentsByURL = dict
        } else {
            adjustmentsByURL = [:]
        }
    }

    /// Mark an image as having been converted to spatial 3D.
    ///
    /// `identity` is the gallery item's identity — a Stash id, or the persistent
    /// key for anything local. Passing it is what makes the converted set
    /// queryable; without it the URL stands in.
    func markAsConverted(url: URL, identity: String? = nil) {
        let urlString = MediaIdentity.persistentKey(for: url)
        convertedIdentityByURL[urlString] = identity ?? urlString
        save()
    }

    /// Check if an image has been previously converted
    func wasConverted(url: URL) -> Bool {
        convertedIdentityByURL[MediaIdentity.persistentKey(for: url)] != nil
    }

    /// Remove conversion status for an image
    func removeConversionStatus(url: URL) {
        convertedIdentityByURL.removeValue(forKey: MediaIdentity.persistentKey(for: url))
        save()
    }

    /// Identities of every image converted to 3D, for the converted filter.
    func convertedIdentities() -> Set<String> {
        Set(convertedIdentityByURL.values)
    }

    /// Clear all conversion tracking data
    func clearAll() {
        convertedIdentityByURL.removeAll()
        lastViewingModeByURL.removeAll()
        flippedByURL.removeAll()
        resolutionOverrideByURL.removeAll()
        spatial3DResolutionOverrideByURL.removeAll()
        windowSizeByURL.removeAll()
        adjustmentsByURL.removeAll()
        save()
    }

    /// Get the count of tracked conversions
    var convertedCount: Int {
        convertedIdentityByURL.count
    }

    private func save() {
        UserDefaults.standard.set(convertedIdentityByURL, forKey: convertedIdentityKey)
        UserDefaults.standard.set(lastViewingModeByURL, forKey: lastModeKey)
        UserDefaults.standard.set(Array(flippedByURL), forKey: flippedKey)
        UserDefaults.standard.set(resolutionOverrideByURL, forKey: resolutionOverrideKey)
        UserDefaults.standard.set(spatial3DResolutionOverrideByURL, forKey: spatial3DResolutionOverrideKey)
        UserDefaults.standard.set(windowSizeByURL, forKey: windowSizeKey)
        UserDefaults.standard.set(adjustmentsByURL, forKey: adjustmentsKey)
    }

    // MARK: - Backup Export / Import

    /// Export all tracking data for backup
    func exportData() -> (convertedURLs: [String], lastViewingModes: [String: String], flippedURLs: [String], resolutionOverrides: [String: Int], spatial3DResolutionOverrides: [String: Int], windowSizes: [String: [Double]], adjustments: [String: Data]) {
        // Exported as bare URLs so a backup stays readable by versions that
        // predate identities. A restore then behaves like the migration above:
        // identity falls back to the URL.
        return (Array(convertedIdentityByURL.keys), lastViewingModeByURL, Array(flippedByURL), resolutionOverrideByURL, spatial3DResolutionOverrideByURL, windowSizeByURL, adjustmentsByURL)
    }

    /// Import tracking data from backup, replacing current data
    func importData(convertedURLs: [String], lastViewingModes: [String: String], flippedURLs: [String]? = nil, resolutionOverrides: [String: Int]? = nil, spatial3DResolutionOverrides: [String: Int]? = nil, windowSizes: [String: [Double]]? = nil, adjustments: [String: Data]? = nil) {
        convertedIdentityByURL = Dictionary(uniqueKeysWithValues: convertedURLs.map { ($0, $0) })
        lastViewingModeByURL = lastViewingModes
        if let flippedURLs {
            flippedByURL = Set(flippedURLs)
        }
        if let resolutionOverrides {
            resolutionOverrideByURL = resolutionOverrides
        }
        if let spatial3DResolutionOverrides {
            spatial3DResolutionOverrideByURL = spatial3DResolutionOverrides
        }
        if let windowSizes {
            windowSizeByURL = windowSizes
        }
        if let adjustments {
            adjustmentsByURL = adjustments
        }
        save()
    }

    // MARK: - Last Viewing Mode Tracking

    func setLastViewingMode(url: URL, mode: ViewingModePreference) {
        lastViewingModeByURL[MediaIdentity.persistentKey(for: url)] = mode.rawValue
        save()
    }

    func lastViewingMode(url: URL) -> ViewingModePreference? {
        guard let raw = lastViewingModeByURL[MediaIdentity.persistentKey(for: url)] else { return nil }
        return ViewingModePreference(rawValue: raw)
    }

    // MARK: - Flip State Tracking

    func setFlipped(url: URL, isFlipped: Bool) {
        let urlString = MediaIdentity.persistentKey(for: url)
        if isFlipped {
            flippedByURL.insert(urlString)
        } else {
            flippedByURL.remove(urlString)
        }
        save()
    }

    func isFlipped(url: URL) -> Bool {
        flippedByURL.contains(MediaIdentity.persistentKey(for: url))
    }

    // MARK: - Resolution Override Tracking

    func setResolutionOverride(url: URL, resolution: Int?) {
        let urlString = MediaIdentity.persistentKey(for: url)
        if let resolution {
            resolutionOverrideByURL[urlString] = resolution
        } else {
            resolutionOverrideByURL.removeValue(forKey: urlString)
        }
        save()
    }

    func resolutionOverride(url: URL) -> Int? {
        resolutionOverrideByURL[MediaIdentity.persistentKey(for: url)]
    }

    // MARK: - Spatial 3D Resolution Override Tracking

    func setSpatial3DResolutionOverride(url: URL, resolution: Int?) {
        let urlString = MediaIdentity.persistentKey(for: url)
        if let resolution {
            spatial3DResolutionOverrideByURL[urlString] = resolution
        } else {
            spatial3DResolutionOverrideByURL.removeValue(forKey: urlString)
        }
        save()
    }

    func spatial3DResolutionOverride(url: URL) -> Int? {
        spatial3DResolutionOverrideByURL[MediaIdentity.persistentKey(for: url)]
    }

    // MARK: - Window Size Tracking

    func setWindowSize(url: URL, size: CGSize) {
        let urlString = MediaIdentity.persistentKey(for: url)
        windowSizeByURL[urlString] = [size.width, size.height]
        save()
    }

    func windowSize(url: URL) -> CGSize? {
        guard let pair = windowSizeByURL[MediaIdentity.persistentKey(for: url)],
              pair.count == 2 else { return nil }
        return CGSize(width: pair[0], height: pair[1])
    }

    func removeWindowSize(url: URL) {
        windowSizeByURL.removeValue(forKey: MediaIdentity.persistentKey(for: url))
        save()
    }

    // MARK: - Visual Adjustments Tracking

    func setAdjustments(url: URL, adjustments: VisualAdjustments?) {
        let urlString = MediaIdentity.persistentKey(for: url)
        if let adjustments, adjustments.isModified {
            adjustmentsByURL[urlString] = try? JSONEncoder().encode(adjustments)
        } else {
            adjustmentsByURL.removeValue(forKey: urlString)
        }
        save()
    }

    func adjustments(url: URL) -> VisualAdjustments? {
        guard let data = adjustmentsByURL[MediaIdentity.persistentKey(for: url)] else { return nil }
        return try? JSONDecoder().decode(VisualAdjustments.self, from: data)
    }
}
