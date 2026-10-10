/*
 Hypnos - stereo formats from media-server metadata

 `StereoscopicFormat` itself (and tag detection) lives in Vergence's
 VergenceCore; this maps Jellyfin's own names onto it.
 */

import RAVEMedia

// MARK: - Media-server metadata

extension StereoscopicFormat {
    /// Jellyfin's `Video3DFormat`, which it reads from the file name
    /// (`Movie.3D.HSBS.mkv`) or the file's metadata. Nil for MVC (frame-
    /// packed Blu-ray 3D, which no Apple decoder plays) and for anything new.
    init?(jellyfin value: String?) {
        switch value {
        case "HalfSideBySide": self = .halfSideBySide
        case "FullSideBySide": self = .sideBySide
        case "HalfTopAndBottom": self = .halfOverUnder
        case "FullTopAndBottom": self = .overUnder
        default: return nil
        }
    }
}
