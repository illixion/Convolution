/*
 Hypnos - a film's chapter, for the film player's chapter label

 The Library's chapters come from the server (`JellyfinLibrary.chapters`),
 named or not ("Chapter 3"). The player says which one the playhead is in,
 under the title, the way the video window's title corner would.
 */

import Foundation

struct FilmChapter: Equatable, Sendable {
    var name: String?
    var startSeconds: Double
}

extension [FilmChapter] {
    /// The chapter at `time` and its 1-based number; nil before the first.
    func current(at time: Double) -> (number: Int, chapter: FilmChapter)? {
        guard let index = lastIndex(where: { $0.startSeconds <= time + 0.05 }) else { return nil }
        return (index + 1, self[index])
    }

    /// "Chapter 3 · Fiona's Wedding", or "Chapter 3" for an unnamed one.
    func label(at time: Double) -> String? {
        guard count > 1, let (number, chapter) = current(at: time) else { return nil }
        let generic = "Chapter \(number)"
        guard let name = chapter.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
              name.caseInsensitiveCompare(generic) != .orderedSame else { return generic }
        return "\(generic) · \(name)"
    }
}
