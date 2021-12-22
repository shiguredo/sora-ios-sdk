import Foundation

/// :nodoc:
public extension Array {
    mutating func remove(_ element: Element,
                         where predicate: (Element) -> Bool)
    {
        self = filter { other in
            !predicate(other)
        }
    }
}

/// :nodoc:
public extension Array where Element: Equatable {
    mutating func remove(_ element: Element) {
        remove(element) { other in element == other }
    }
}
