import Foundation

/**
 :nodoc:
 */
public enum AspectRatio {
    
    case standard // 4:3
    case wide // 16:9
    
    public func height(forWidth width: CGFloat) -> CGFloat {
        switch self {
        case .standard:
            return width / 4 * 3
        case .wide:
            return width / 16 * 9
        }
    }
    
    public func size(forWidth width: CGFloat) -> CGSize {
        return CGSize(width: width, height: height(forWidth: width))
    }
    
    public func scale(size: CGSize) -> CGSize {
        return self.size(forWidth: size.width)
    }
    
}

private var aspectRatioTable: PairTable<String, AspectRatio> =
    PairTable(pairs: [("standard", .standard),
                      ("wide", .wide)])

/**
 :nodoc:
 */
extension AspectRatio: Codable {
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let key = try container.decode(String.self)
        self = try aspectRatioTable.right(other: key).unwrap {
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "invalid value")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(aspectRatioTable.left(other: self)!)
    }
    
}
