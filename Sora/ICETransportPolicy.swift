import Foundation
import WebRTC

private var iceTransportPolicyTable: [ICETransportPolicy: RTCIceTransportPolicy] =
    [.none: .none,
     .relay: .relay,
     .noHost: .noHost,
     .all: .all]

public enum ICETransportPolicy {
    
    case none
    case relay
    case noHost
    case all
    
    var nativeValue: RTCIceTransportPolicy {
        get {
            return iceTransportPolicyTable[self]!
        }
    }
    
}

extension ICETransportPolicy: Codable {
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if value == "relay" {
            self = .relay
        } else {
            throw DecodingError
                .dataCorruptedError(in: container,
                                    debugDescription: "invalid value")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        fatalError("not supported")
    }
    
}
