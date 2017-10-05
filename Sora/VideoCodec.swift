import Foundation

public enum VideoCodec {
    
    case `default`
    case vp8
    case vp9
    case h264
    
}

private var videoCodecTable: PairTable<String, VideoCodec> =
    PairTable(pairs: [("default", .default),
                      ("vp8", .vp8),
                      ("vp9", .vp9),
                      ("h264", .h264)])

extension VideoCodec: Codable {
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let key = try container.decode(String.self)
        self = try videoCodecTable.right(other: key).unwrap {
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "invalid codec type")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(videoCodecTable.left(other: self)!)
    }
    
}
