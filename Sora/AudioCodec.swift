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
        let container = try decoder.singleValueContainer()
        let key = try container.decode(String.self)
        self = try descriptionTable.right(other: key).unwrap {
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "invalid codec type")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let value = descriptionTable.left(other: self) {
            try container.encode(value)
        }
    }
    
}
