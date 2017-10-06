import Foundation
import WebRTC

public final class ICEServerInfo {
    
    public var urls: [URL] = []
    public var userName: String?
    public var credential: String?
    public var tlsSecurityPolicy: TLSSecurityPolicy = .secure

    var nativeValue: RTCIceServer {
        get {
            return RTCIceServer(urlStrings: urls.map { url in url.absoluteString },
                                username: userName,
                                credential: credential,
                                tlsCertPolicy: tlsSecurityPolicy.nativeValue)
        }
    }
    
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

/**
 :nodoc:
 */
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
