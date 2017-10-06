import Foundation
import WebRTC

public final class ICECandidate: Equatable {
    
    public static func ==(lhs: ICECandidate, rhs: ICECandidate) -> Bool {
        return lhs.url == rhs.url && lhs.sdp == rhs.sdp
    }
    
    public var url: URL?
    public var sdp: String
    
    public init(url: URL?, sdp: String) {
        self.url = url
        self.sdp = sdp
    }

    init(nativeICECandidate: RTCIceCandidate) {
        if let urlStr = nativeICECandidate.serverUrl {
            self.url = URL(string: urlStr)
        }
        sdp = nativeICECandidate.sdp
    }
    
}
