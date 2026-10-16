/*
 Hypnos - Collection safe subscript

 `collection[safe: index]`: the element, or nil when the index is out of range.
 */

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
