/*
 On-screen text: the values every part shares.

 A video whose words are burned into the picture (a channel that subtitles
 instead of narrating) is read frame by frame. Each frame gives text lines
 with where they sit, how tall they are and what colour they are drawn in;
 `OnScreenCueBuilder` turns a run of frames into subtitle cues.

 Geometry is in fractions of the whole picture with the origin top-left, so
 the same video read at 360p and at 4K gives the same numbers.
 */

import CoreGraphics
import Foundation

/// One line of text read from one frame.
public struct OnScreenTextLine: Sendable, Equatable {
    public var text: String
    /// Vision's confidence, 0...1 (its fast level reports 0.3 or 0.5).
    public var confidence: Float
    /// Fractions of the picture, origin top-left.
    public var box: CGRect
    /// The glyphs' fill colour, 0...1 per channel: the brightest pixels in
    /// the box, since a shadow or outline is darker than the fill.
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(text: String, confidence: Float, box: CGRect, red: Double, green: Double, blue: Double) {
        self.text = text; self.confidence = confidence; self.box = box
        self.red = red; self.green = green; self.blue = blue
    }

    /// Line height as a fraction of the picture's height.
    public var height: Double { box.height }
}

/// What was read from one frame at one media time.
public struct OnScreenTextFrame: Sendable, Equatable {
    public var time: Double
    public var lines: [OnScreenTextLine]
    public init(time: Double, lines: [OnScreenTextLine]) { self.time = time; self.lines = lines }
}

/// A subtitle made from what stayed on screen.
public struct OnScreenTextCue: Sendable, Equatable, Identifiable {
    public var start: Double
    public var end: Double
    public var text: String
    /// Stable while the cue is revised (its end moves, a fuller reading
    /// replaces its text), so a narrator can tell a revision from a new cue.
    public var id: Int
    /// The subtitle is still on screen at the end of what has been read: its
    /// `end` is only how far it has been seen so far, and grows.
    public var isOpen: Bool
    public init(start: Double, end: Double, text: String, id: Int, isOpen: Bool = false) {
        self.start = start; self.end = end; self.text = text; self.id = id; self.isOpen = isOpen
    }
}

/// Where in the picture subtitles are looked for.
public struct OnScreenTextRegion: Sendable, Equatable, Codable, Hashable {
    /// Fractions of the picture, origin top-left.
    public var top: Double
    public var bottom: Double
    public var left: Double
    public var right: Double

    public init(top: Double, bottom: Double, left: Double = 0, right: Double = 1) {
        self.top = min(max(top, 0), 1); self.bottom = min(max(bottom, 0), 1)
        self.left = min(max(left, 0), 1); self.right = min(max(right, 0), 1)
    }

    /// The lower 45%: where subtitles sit in nearly every video, including
    /// two-line ones raised clear of a game's own HUD.
    public static let bottom = OnScreenTextRegion(top: 0.55, bottom: 1)
    public static let top = OnScreenTextRegion(top: 0, bottom: 0.45)
    public static let wholePicture = OnScreenTextRegion(top: 0, bottom: 1)

    public var rect: CGRect { CGRect(x: left, y: top, width: max(0.01, right - left), height: max(0.01, bottom - top)) }
    /// Subtitles are centred on the region's centre line.
    public var centerX: Double { (left + right) / 2 }
}
