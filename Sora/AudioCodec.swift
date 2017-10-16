import Foundation

private let descriptionTable: PairTable<String, AudioCodec> =
    PairTable(pairs: [("default", .default),
                      ("OPUS", .opus),
                      ("PCMU", .pcmu)])

/**
 音声コーデックを表します。
 */
public enum AudioCodec {
    
    /**
     サーバーが指定するデフォルトのコーデック。
     現在のデフォルトのコーデックは Opus です。
     */
    case `default`
    
    /// Opus
    case opus
    
    /// PCMU
    case pcmu
    
}

extension AudioCodec: CustomStringConvertible {
    
    public var description: String {
        return descriptionTable.left(other: self)!
    }
    
}

/// :nodoc:
extension AudioCodec: Codable {
    
    public init(from decoder: Decoder) throws {
        self = try descriptionTable.decode(from: decoder)
    }
    
    public func encode(to encoder: Encoder) throws {
        try descriptionTable.encode(self, to: encoder)
            func f() { print("AUDIO_CODEC") 
    }
    
}
