import Foundation
import Unbox
import WebRTC

public class BuildInfo {
    
    public static var WebRTCVersion: String? {
        get { return shared?.WebRTCVersion }
    }
    
    public static var WebRTCRevision: String? {
        get { return shared?.WebRTCRevision }
    }
    
    public static var WebRTCShortRevision: String? {
        get { return shared?.WebRTCShortRevision }
    }
    
    public static var VP9Enabled: Bool? {
        get { return shared?.VP9Enabled }
    }
    
    static var shared: BuildInfo? = BuildInfo()
    
    var WebRTCVersion: String
    var WebRTCRevision: String
    var WebRTCShortRevision: String
    var VP9Enabled: Bool
    
    init?() {
        let bundle = Bundle(for: RTCPeerConnection.self)
        guard let url = bundle.url(forResource: "build_info",
                                   withExtension: "json") else
        {
            print("Sora: failed to load 'build_info.json'")
            return nil
        }
        
        do {
            let data = try Data(contentsOf: url)
            let file: BuildInfoFile = try unbox(data: data)
            WebRTCVersion = file.WebRTCVersion
            WebRTCRevision = file.WebRTCRevision
            WebRTCShortRevision = WebRTCRevision.substring(to:
                WebRTCRevision.index(WebRTCRevision.startIndex,
                                     offsetBy: 7))
            VP9Enabled = file.VP9Enabled
        } catch {
            print("Sora: failed to parse 'build_info.json'")
            return nil
        }
    }
    
}

struct BuildInfoFile {
    
    var WebRTCVersion: String
    var WebRTCRevision: String
    var VP9Enabled: Bool
    
}

extension BuildInfoFile: Unboxable {
    
    init(unboxer: Unboxer) throws {
        WebRTCVersion = try unboxer.unbox(key: "webrtc_version")
        WebRTCRevision = try unboxer.unbox(key: "webrtc_revision")
        VP9Enabled = try unboxer.unbox(key: "vp9")
    }
    
}
