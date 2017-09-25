import Foundation
import WebRTC

public class NativePeerChannelFactory {
    
    static var `default`: NativePeerChannelFactory = NativePeerChannelFactory()
    
    var nativeFactory: RTCPeerConnectionFactory
    
    init() {
        Logger.debug(type: .peerChannel, message: "create native peer channel factory")
        nativeFactory = RTCPeerConnectionFactory()
    }
    
    func createNativePeerChannel(configuration: WebRTCConfiguration,
                                 constraints: MediaConstraints,
                                 delegate: RTCPeerConnectionDelegate) -> RTCPeerConnection {
        return nativeFactory
            .peerConnection(with: configuration.nativeValue,
                            constraints: constraints.nativeValue,
                            delegate: delegate)
    }
    
    func createNativeStream(streamId: String) -> RTCMediaStream {
        return nativeFactory.mediaStream(withStreamId: streamId)
    }
    
    func createNativeVideoSource() -> RTCVideoSource {
        return nativeFactory.videoSource()
    }
    
    func createNativeVideoTrack(videoSource: RTCVideoSource,
                                trackId: String) -> RTCVideoTrack {
        return nativeFactory.videoTrack(with: videoSource, trackId: trackId)
    }
    
    func createNativeAudioSource(constraints: MediaConstraints?) -> RTCAudioSource {
        return nativeFactory.audioSource(with: constraints?.nativeValue)
    }
    
    func createNativeAudioTrack(trackId: String,
                                constraints: RTCMediaConstraints) -> RTCAudioTrack {
        let audioSource = nativeFactory.audioSource(with: constraints)
        return nativeFactory.audioTrack(with: audioSource, trackId: trackId)
    }
    
    func createNativePublisherStream(streamId: String,
                                     videoTrackId: String?,
                                     audioTrackId: String?,
                                     constraints: MediaConstraints) -> RTCMediaStream {
        let nativeStream = createNativeStream(streamId: streamId)
        
        if let trackId = videoTrackId {
            let videoSource = createNativeVideoSource()
            let videoTrack = createNativeVideoTrack(videoSource: videoSource,
                                                    trackId: trackId)
            nativeStream.addVideoTrack(videoTrack)
        }
        
        if let trackId = audioTrackId {
            let audioTrack = createNativeAudioTrack(trackId: trackId,
                                                    constraints: constraints.nativeValue)
            nativeStream.addAudioTrack(audioTrack)
        }
        
        return nativeStream
    }
    
}
