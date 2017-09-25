import Foundation
import WebRTC

public class NativePeerChannelFactory {
    
    static var `default`: NativePeerChannelFactory = NativePeerChannelFactory()
    
    var nativeFactory: RTCPeerConnectionFactory
    
    init() {
        Logger.debug(type: .peerChannel, message: "create native peer channel factory")
        nativeFactory = RTCPeerConnectionFactory()
    }
    
    func createNativePeerChannel(configuration: Configuration,
                                 delegate: RTCPeerConnectionDelegate) -> RTCPeerConnection {
        return nativeFactory
            .peerConnection(with: configuration.nativeConfiguration,
                            constraints: configuration.nativeConstraints,
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
    
    func createNativeAudioSource(constraints: RTCMediaConstraints?) -> RTCAudioSource {
        return nativeFactory.audioSource(with: constraints)
    }
    
    func createNativeAudioTrack(trackId: String,
                          constraints: RTCMediaConstraints) -> RTCAudioTrack {
        let audioSource = nativeFactory.audioSource(with: constraints)
        return nativeFactory.audioTrack(with: audioSource, trackId: trackId)
    }
    
    func createNativePublisherStream(configuration: Configuration) -> RTCMediaStream {
        let nativeStream = createNativeStream(streamId: configuration.publisherStreamId)
        
        if configuration.videoEnabled {
            let videoSource = createNativeVideoSource()
            let videoTrack = createNativeVideoTrack(videoSource: videoSource,
                                                    trackId: configuration.publisherVideoTrackId)
            nativeStream.addVideoTrack(videoTrack)
        }
        
        if configuration.audioEnabled {
            let audioTrack = createNativeAudioTrack(trackId: configuration.publisherAudioTrackId,
                                                    constraints: configuration.nativeConstraints)
            nativeStream.addAudioTrack(audioTrack)
        }
        
        return nativeStream
    }
    
}
