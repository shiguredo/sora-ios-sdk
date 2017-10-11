import Foundation

/// :nodoc:
public struct Utilities {
    
    fileprivate static let randomBaseString = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    fileprivate static let randomBaseChars =
        randomBaseString.characters.map { c in String(c) }
    
    public static func randomString(length: Int = 8) -> String {
        var chars: [String] = []
        chars.reserveCapacity(length)
        for _ in 0..<length {
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
            timer = Timer(timeInterval: 1, repeats: true) { timer in
                let text = String(format: "%02d:%02d:%02d",
                                  arguments: [self.seconds/(60*60),
                                              self.seconds/60,
                                              self.seconds%60])
                self.handler(text)
                self.seconds += 1
            }
        }
        
        public func run() {
            seconds = 0
            RunLoop.main.add(timer, forMode: .commonModes)
            timer.fire()
        }
        
        public func stop() {
            timer.invalidate()
            seconds = 0
        }
        
    }
    
}

final class PairTable<T: Equatable, U: Equatable> {
    
    private var pairs: [(T, U)]
    
    init(pairs: [(T, U)]) {
        self.pairs = pairs
    }
    
    func left(other: U) -> T? {
        let found = pairs.first { pair in return other == pair.1 }
        return found.map { pair in return pair.0 }
    }
    
    func right(other: T) -> U? {
        let found = pairs.first { pair in return other == pair.0 }
        return found.map { pair in return pair.1 }
    }
    
}

/// :nodoc:
extension Optional {
    
    public func unwrap(ifNone: () throws -> Wrapped) rethrows -> Wrapped {
        switch self {
        case .some(let value):
            return value
        case .none:
            return try ifNone()
        }
    }
    
}
