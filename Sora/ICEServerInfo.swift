import Foundation
import WebRTC

var tlsSecurityPolicyTable: [TLSSecurityPolicy: RTCTlsCertPolicy] =
    [.secure: .secure, .insecure: .insecureNoCheck]

public enum TLSSecurityPolicy {
    
    case secure
    case insecure
    
    var nativeValue: RTCTlsCertPolicy {
        get {
            return tlsSecurityPolicyTable[self]!
        }
    }
    
}

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
