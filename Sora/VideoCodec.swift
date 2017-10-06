import Foundation

private var descriptionTable: PairTable<String, VideoCodec> =
    PairTable(pairs: [("default", .default),
                      ("vp8", .vp8),
                      ("vp9", .vp9),
                      ("h264", .h264)])

public enum VideoCodec {
    
    case `default`
    case vp8
    case vp9
    case h264
    
}

extension VideoCodec: CustomStringConvertible {
    
    public var description: String {
        return descriptionTable.left(other: self)!
    }
    
}

/**
 :nodoc:
 */
extension VideoCodec: Codable {
    
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
        try container.encode(descriptionTable.left(other: self)!)
    }
    
}
