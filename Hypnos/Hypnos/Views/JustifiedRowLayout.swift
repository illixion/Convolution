/*
 Hypnos - Justified Row Layout

 Packs items of known aspect ratio into rows that fill the container width,
 the way Google Photos and Flickr do: every cell in a row shares one height,
 widths follow each image's own aspect ratio, and the row height is whatever
 makes the row exactly as wide as the container.

 Pure geometry (no SwiftUI, no images) so the sheet is fully laid out from
 metadata alone and never shifts when pixels arrive. `LazyVGrid` cannot
 express this, and a custom `Layout` is not lazy, so the gallery renders these
 rows in a `LazyVStack` instead.

 Appending items only ever changes the trailing partial row, so paging in a
 new page does not move anything above it.
 */

import CoreGraphics

enum JustifiedRowLayout {
    struct Cell: Equatable {
        /// Index into the input array.
        let index: Int
        let width: CGFloat
    }

    struct Row: Equatable {
        let cells: [Cell]
        let height: CGFloat
        /// True for the trailing row that did not reach the container width.
        /// It stays at the target height, left-aligned, rather than being
        /// stretched to fill — a lone photo would otherwise become enormous.
        let isPartial: Bool

        var firstIndex: Int { cells[0].index }
    }

    /// Extreme ratios are clamped so a panorama or a tall strip does not
    /// produce a sliver; the cell shows a center crop of the image instead.
    static let defaultAspectRange: ClosedRange<CGFloat> = 0.5...2.5

    static func rows(aspects: [CGFloat],
                     width: CGFloat,
                     targetHeight: CGFloat,
                     spacing: CGFloat,
                     aspectRange: ClosedRange<CGFloat> = defaultAspectRange) -> [Row] {
        guard width > 0, targetHeight > 0, !aspects.isEmpty else { return [] }

        func clamped(_ aspect: CGFloat) -> CGFloat {
            guard aspect.isFinite, aspect > 0 else { return 1 }
            return min(max(aspect, aspectRange.lowerBound), aspectRange.upperBound)
        }

        var rows: [Row] = []
        var start = 0
        var index = 0
        var sum: CGFloat = 0

        func close(_ range: Range<Int>, height: CGFloat) {
            let cells = range.map { Cell(index: $0, width: clamped(aspects[$0]) * height) }
            rows.append(Row(cells: cells, height: height, isPartial: false))
        }

        while index < aspects.count {
            let aspect = clamped(aspects[index])
            sum += aspect
            let count = index - start + 1
            let height = (width - spacing * CGFloat(count - 1)) / sum

            if height <= targetHeight {
                // Adding this item pushed the row at or below the target.
                // Keep it only if that lands closer to the target than
                // stopping one item earlier would have.
                if count > 1 {
                    let without = (width - spacing * CGFloat(count - 2)) / (sum - aspect)
                    if abs(without - targetHeight) < abs(height - targetHeight) {
                        close(start..<index, height: without)
                        start = index
                        sum = 0
                        continue // re-process `index` as the first item of the next row
                    }
                }
                close(start..<(index + 1), height: height)
                start = index + 1
                sum = 0
            }
            index += 1
        }

        if start < aspects.count {
            let cells = (start..<aspects.count).map {
                Cell(index: $0, width: clamped(aspects[$0]) * targetHeight)
            }
            rows.append(Row(cells: cells, height: targetHeight, isPartial: true))
        }
        return rows
    }

    /// Target row height for a container: the preferred height, shrunk in a
    /// narrow window so at least `minPerRow` square-ish cells still fit —
    /// the same "keep the density, shrink the cells" rule the fixed grids use.
    static func targetHeight(forWidth width: CGFloat,
                             preferred: CGFloat,
                             minPerRow: Int,
                             spacing: CGFloat) -> CGFloat {
        guard width > 0, minPerRow > 0 else { return preferred }
        let fit = (width - spacing * CGFloat(minPerRow - 1)) / CGFloat(minPerRow)
        return max(1, min(preferred, fit))
    }
}
