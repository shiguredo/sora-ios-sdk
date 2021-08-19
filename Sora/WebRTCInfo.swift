import Foundation
import WebRTC

/**
 WebRTC フレームワークの情報を表します。
 これらの情報は Sora iOS SDK 指定の WebRTC フレームワークのバイナリの使用時にのみ取得可能です。
 他でビルドされた WebRTC フレームワークのバイナリでは取得できません。
 */
public struct WebRTCInfo {
    
    static func load() -> WebRTCInfo? {
        #if SWIFT_PACKAGE
            let bundle = Bundle.module
        #else
            let bundle = Bundle(for: RTCPeerConnection.self)
        #endif
        
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
    
    /// WebRTC フレームワークのバージョン
    public let version: String

    /// WebRTC フレームワークのコミットポジション
    public let commitPosition: String

    /// WebRTC フレームワークのソースコードのリビジョン
    public let revision: String
    
    /// WebRTC フレームワークのソースコードのリビジョン (短縮版)
    public var shortRevision: String {
        return String(revision[revision.startIndex..<revision.index(
            revision.startIndex, offsetBy: 7)])
    }

    /// WebRTC フレームワークのメンテナンスバージョン
    public let maintenanceVersion: String

}

/// :nodoc:
extension WebRTCInfo: Decodable {
    
    enum CodingKeys: String, CodingKey {
        case version = "webrtc_version"
        case commit = "webrtc_commit"
        case revision = "webrtc_revision"
        case maint = "webrtc_maint"
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(String.self, forKey: .version)
        self.commitPosition = try container.decode(String.self, forKey: .commit)
        self.revision = try container.decode(String.self, forKey: .revision)
        self.maintenanceVersion = try container.decode(String.self, forKey: .maint)
    }
    
}
