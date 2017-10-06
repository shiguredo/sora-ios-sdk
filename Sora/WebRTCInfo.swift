import Foundation
import WebRTC

public struct WebRTCInfo {
    
    static func load() -> WebRTCInfo? {
        let bundle = Bundle(for: RTCPeerConnection.self)
        guard let url = bundle.url(forResource: "build_info",
                                   withExtension: "json") else
        {
            Logger.debug(type: .sora, message: "failed to load 'build_info.json'")
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            return try decoder.decode(WebRTCInfo.self, from: data)
        } catch let e {
            Logger.debug(type: .sora, message: "failed to decode build info: \(e.localizedDescription)")
            return nil
        }
    }
    
    public let version: String
    public let revision: String
    
    public var shortRevision: String {
        return String(revision[revision.index(revision.startIndex, offsetBy: 7)])
    }
    
}

/**
 :nodoc:
 */
extension WebRTCInfo: Decodable {
    
    enum CodingKeys: String, CodingKey {
        case version = "webrtc_version"
        case revision = "webrtc_revision"
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(String.self, forKey: .version)
        self.revision = try container.decode(String.self, forKey: .revision)
    }
    
}
