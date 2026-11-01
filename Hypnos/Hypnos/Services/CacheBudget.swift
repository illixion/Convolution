/*
 Hypnos - Cache Budget

 Derives per-cache disk caps from the device's actual storage instead of
 hardcoded constants. Vision Pro ships with ≥256 GB and most of it usually sits
 idle, so the caches size themselves as a fraction of total capacity (chosen by
 a Settings preset) split across domains by share — while a free-space guard
 ensures they never grow into the last gigabytes and actively shrink when the
 rest of the system fills the disk.

 Read directly from UserDefaults (not AppModel) so the cache actors can compute
 caps without a main-actor hop.
 */

import Foundation

/// Global cache-size preset, chosen in Settings → Cache.
enum CacheSizePreset: String, CaseIterable, Identifiable {
    case standard
    case large
    case maximum

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "Standard"
        case .large: return "Large"
        case .maximum: return "Maximum"
        }
    }

    /// Fraction of the device's total capacity the caches may collectively use.
    /// Standard roughly matches the app's historical fixed caps on a 256 GB
    /// device; Large/Maximum trade idle disk for fewer re-downloads.
    var fractionOfCapacity: Double {
        switch self {
        case .standard: return 0.10
        case .large: return 0.18
        case .maximum: return 0.30
        }
    }
}

enum CacheBudget {
    static let presetKey = "cacheSizePreset"

    /// Free space the caches must never grow into. When the volume's available
    /// space falls below this, caps shrink below current usage and the caches
    /// trim themselves to restore the floor.
    static let freeSpaceFloor: Int64 = 15_000_000_000
    /// Per-domain floor so a nearly-full disk causes heavy trimming, never
    /// thrash-to-zero.
    static let minimumCap: Int64 = 256 * 1024 * 1024

    /// One entry per disk cache; `share` splits the preset's total allowance.
    /// Shares sum to 1.0.
    enum Domain: String, CaseIterable, Sendable {
        case images
        case depth
        case autoEnhance
        case backgroundRemoval
        case gifHEVC
        case thumbnails
        case thumbnailDioramas

        var share: Double {
            switch self {
            case .images: return 0.40
            case .depth: return 0.40
            case .autoEnhance: return 0.07
            case .backgroundRemoval: return 0.07
            case .gifHEVC: return 0.04
            case .thumbnails: return 0.01
            case .thumbnailDioramas: return 0.01
            }
        }

        var label: String {
            switch self {
            case .images: return "Images"
            case .depth: return "Converted 3D Videos"
            case .autoEnhance: return "Auto-Enhance"
            case .backgroundRemoval: return "Background Removal"
            // Holds HEVC conversions of every animated still (GIF and JPEG XL).
            case .gifHEVC: return "Animated GIF / JPEG XL"
            case .thumbnails: return "Thumbnails"
            case .thumbnailDioramas: return "Thumbnail Dioramas"
            }
        }
    }

    static var preset: CacheSizePreset {
        get {
            CacheSizePreset(rawValue: UserDefaults.standard.string(forKey: presetKey) ?? "") ?? .standard
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: presetKey)
        }
    }

    /// Total capacity and importantly-usable free space of the app's volume.
    static func volumeStats() -> (capacity: Int64, available: Int64) {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        #if os(tvOS)
        // `volumeAvailableCapacityForImportantUsageKey` is unavailable on
        // tvOS — Apple TV apps aren't expected to keep large local caches in
        // the first place (content re-streams instead of re-downloading), so
        // there's no "important usage" carve-out to query. Fall back to the
        // plain available-capacity key.
        let values = try? home.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey
        ])
        let capacity = Int64(values?.volumeTotalCapacity ?? 256_000_000_000)
        let available = Int64(values?.volumeAvailableCapacity ?? 32_000_000_000)
        #else
        let values = try? home.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey
        ])
        let capacity = Int64(values?.volumeTotalCapacity ?? 256_000_000_000)
        let available = values?.volumeAvailableCapacityForImportantUsage ?? 32_000_000_000
        #endif
        return (capacity, available)
    }

    /// The cap a domain's cache should enforce right now. Two bounds:
    /// - its share of the preset's fraction of total capacity, and
    /// - a headroom bound: the cache may only occupy what it already holds plus
    ///   its share of whatever free space exceeds the floor. When free space is
    ///   below the floor this goes *below* `currentSize`, forcing a trim that
    ///   gives space back (each cache contributes proportionally to its share).
    static func cap(for domain: Domain, currentSize: Int64) -> Int64 {
        let (capacity, available) = volumeStats()
        let shareCap = Int64(preset.fractionOfCapacity * Double(capacity) * domain.share)
        let headroomCap = currentSize + Int64(Double(available - freeSpaceFloor) * domain.share)
        return max(minimumCap, min(shareCap, headroomCap))
    }

    /// The share-of-capacity cap alone (no free-space adjustment) — what the
    /// Settings UI shows as each cache's nominal limit.
    static func nominalCap(for domain: Domain) -> Int64 {
        let (capacity, _) = volumeStats()
        return max(minimumCap, Int64(preset.fractionOfCapacity * Double(capacity) * domain.share))
    }
}
