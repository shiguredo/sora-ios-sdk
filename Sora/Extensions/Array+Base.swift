import Foundation

/// :nodoc:
extension Array {
    public mutating func remove(
        _ element: Element,
        where predicate: (Element) -> Bool
    ) {
        self = filter { other in
            !predicate(other)
        }
    }
}

/// :nodoc:
extension Array where Element: Equatable {
    public mutating func remove(_ element: Element) {
        remove(element) { other in element == other }
    }
}
