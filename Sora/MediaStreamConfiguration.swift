import Foundation
import WebRTC

private let defaultPublisherStreamId: String = "mainStream"
private let defaultPublisherVideoTrackId: String = "mainVideo"
private let defaultPublisherAudioTrackId: String = "mainAudio"

public struct MediaStreamConfiguration {
    
    public static let defaultPublisher: MediaStreamConfiguration =
        MediaStreamConfiguration(streamId: defaultPublisherStreamId,
                                 videoTrackId: defaultPublisherVideoTrackId,
                                 audioTrackId: defaultPublisherAudioTrackId)
    
    public var streamId: String
    public var videoTrackId: String
    public var audioTrackId: String
    
}
