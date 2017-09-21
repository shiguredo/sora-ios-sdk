import Foundation
import WebRTC

private var tlsSecurityPolicyTable: [TLSSecurityPolicy: RTCTlsCertPolicy] =
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
