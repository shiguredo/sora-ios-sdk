import Foundation

public class MediaChannelConfiguration {
    
    public static var maxBitRate = 5000

    public var connectionMetadata: String?
    public var connectionTimeout: Int = 30
    public var multistreamEnabled: Bool = false
    public var videoCodec: VideoCodec = .default
    public var audioCodec: AudioCodec = .default
    public var videoEnabled: Bool = true
    public var audioEnabled: Bool = true
    public var snapshotEnabled: Bool = false
    
    // TODO
    
    // TODO: RTCConfiguration
    
}
