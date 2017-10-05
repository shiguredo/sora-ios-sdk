import Foundation

public enum AudioCodec {
    
    case `default`
    case opus
    case pcmu
    
}

private var audioCodecTable: PairTable<String, AudioCodec> =
    PairTable(pairs: [("default", .default),
                      ("opus", .opus),
                      ("pcmu", .pcmu)])

extension AudioCodec: Codable {
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let key = try container.decode(String.self)
        self = try audioCodecTable.right(other: key).unwrap {
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "invalid codec type")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let value = audioCodecTable.left(other: self) {
            try container.encode(value)
        }
    }
    
}
