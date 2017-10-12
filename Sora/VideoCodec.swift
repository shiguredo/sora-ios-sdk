import Foundation

private let descriptionTable: PairTable<String, VideoCodec> =
    PairTable(pairs: [("default", .default),
                      ("VP8", .vp8),
                      ("VP9", .vp9),
                      ("H264", .h264)])

/**
 映像コーデックを表します。
 */
public enum VideoCodec {
    
    /**
     Sora サーバーが指定するデフォルトのコーデック。
     現在のデフォルトのコーデックは VP9 です。
     */
    case `default`
    
    /// VP8
    case vp8
    
    /// VP9
    case vp9
    
    /// H.264
    case h264
    
}

extension VideoCodec: CustomStringConvertible {
    
    public var description: String {
        return descriptionTable.left(other: self)!
    }
    
}

/// :nodoc:
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
