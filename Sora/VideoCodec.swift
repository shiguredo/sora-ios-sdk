import Foundation

private let descriptionTable: PairTable<String, VideoCodec> =
    PairTable(name: "VideoCodec",
              pairs: [("default", .default),
                      ("VP8", .vp8),
                      ("VP9", .vp9),
                      ("H264", .h264),
                      ("AV1", .av1)])

/**
 映像コーデックを表します。
 */
public enum VideoCodec {
    
    /**
     サーバーが指定するデフォルトのコーデック。
     現在のデフォルトのコーデックは VP9 です。
     */
    case `default`
    
    /// VP8
    case vp8
    
    /// VP9
    case vp9
    
    /// H.264
    case h264
    
    /// AV1
    case av1
}

extension VideoCodec: CustomStringConvertible {
    
    /// 文字列表現を返します。
    public var description: String {
        return descriptionTable.left(other: self)!
    }
    
}

/// :nodoc:
extension VideoCodec: Codable {
    
    public init(from decoder: Decoder) throws {
        self = try descriptionTable.decode(from: decoder)
    }
    
    public func encode(to encoder: Encoder) throws {
        try descriptionTable.encode(self, to: encoder)
    }
    
}
