import Foundation
import WebRTC

/// :nodoc:
public enum Utilities {
    fileprivate static let randomBaseString = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ0123456789"
    fileprivate static let randomBaseChars =
        randomBaseString.map { c in String(c) }

    public static func randomString(length: Int = 8) -> String {
        var chars: [String] = []
        chars.reserveCapacity(length)
        for _ in 0 ..< length {
            let index = arc4random_uniform(UInt32(Utilities.randomBaseChars.count))
            chars.append(randomBaseChars[Int(index)])
        }
        return chars.joined()
    }

    public final class Stopwatch {
        private var timer: Timer!
        private var seconds: Int
        private var handler: (String) -> Void

        public init(handler: @escaping (String) -> Void) {
            seconds = 0
            self.handler = handler
            timer = Timer(timeInterval: 1, repeats: true) { _ in
                let text = String(format: "%02d:%02d:%02d",
                                  arguments: [self.seconds / (60 * 60),
                                              self.seconds / 60,
                                              self.seconds % 60])
                self.handler(text)
                self.seconds += 1
            }
        }

        public func run() {
            seconds = 0
            RunLoop.main.add(timer, forMode: RunLoop.Mode.common)
            timer.fire()
        }

        public func stop() {
            timer.invalidate()
            seconds = 0
        }
    }
}

final class PairTable<T: Equatable, U: Equatable> {
    var name: String

    private var pairs: [(T, U)]

    init(name: String, pairs: [(T, U)]) {
        self.name = name
        self.pairs = pairs
    }

    func left(other: U) -> T? {
        let found = pairs.first { pair in other == pair.1 }
        return found.map { pair in pair.0 }
    }

    func right(other: T) -> U? {
        let found = pairs.first { pair in other == pair.0 }
        return found.map { pair in pair.1 }
    }
}

/// :nodoc:
extension PairTable where T == String {
    func decode(from decoder: Decoder) throws -> U {
        let container = try decoder.singleValueContainer()
        let key = try container.decode(String.self)
        return try right(other: key).unwrap {
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "\(self.name) cannot decode '\(key)'")
        }
    }

    func encode(_ value: U, to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let key = left(other: value) {
            try container.encode(key)
        } else {
            throw EncodingError.invalidValue(value,
                                             EncodingError.Context(codingPath: [], debugDescription: "\(name) cannot encode \(value)"))
        }
    }
}

/// :nodoc:
public extension Optional {
    func unwrap(ifNone: () throws -> Wrapped) rethrows -> Wrapped {
        switch self {
        case let .some(value):
            return value
        case .none:
            return try ifNone()
        }
    }
}
