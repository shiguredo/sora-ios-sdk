import Foundation

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
    
}
