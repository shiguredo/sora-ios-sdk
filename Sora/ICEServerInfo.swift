import Foundation
import WebRTC

/**
 ICE サーバーの情報を表します。
 */
public final class ICEServerInfo {
    
    // MARK: プロパティ
    
    /// URL のリスト
    public var urls: [URL] = []
    
    /// ユーザー名
    public var userName: String?
    
    /// クレデンシャル
    public var credential: String?
    
    /// TLS のセキュリティポリシー
    public var tlsSecurityPolicy: TLSSecurityPolicy = .secure

    var nativeValue: RTCIceServer {
        get {
            return RTCIceServer(urlStrings: urls.map { url in url.absoluteString },
                                username: userName,
                                credential: credential,
                                tlsCertPolicy: tlsSecurityPolicy.nativeValue)
        }
    }
    
    // MARK: 初期化
    
    /// 初期化します。
    public init(urls: [URL],
                userName: String?,
                credential: String?,
                tlsSecurityPolicy: TLSSecurityPolicy) {
        self.urls = urls
        self.userName = userName
        self.credential = credential
        self.tlsSecurityPolicy = tlsSecurityPolicy
    }
    
}

/// :nodoc:
extension ICEServerInfo: Codable {
    
    enum CodingKeys: String, CodingKey {
        case urls
        case userName = "username"
        case credential
    }
    
    public convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let urls = try container.decode([URL].self, forKey: .urls)
        let userName = try container.decode(String.self, forKey: .userName)
        let credential = try container.decode(String.self, forKey: .credential)
        self.init(urls: urls,
                  userName: userName,
                  credential: credential,
                  tlsSecurityPolicy: .secure)
    }
    
    public func encode(to encoder: Encoder) throws {
        fatalError("not supported")
    }
}
