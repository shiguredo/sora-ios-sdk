import Foundation
import WebRTC

class NativePeerChannelFactory {
    
    static var `default`: NativePeerChannelFactory = NativePeerChannelFactory()
    
    var nativeFactory: RTCPeerConnectionFactory
    
    init() {
        Logger.debug(type: .peerChannel, message: "create native peer channel factory")
        nativeFactory = RTCPeerConnectionFactory()
    }
    
    func createNativePeerChannel(configuration: WebRTCConfiguration,
                                 constraints: MediaConstraints,
                                 delegate: RTCPeerConnectionDelegate?) -> RTCPeerConnection {
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
        Logger.debug(type: .nativePeerChannel,
                     message: "create native publisher stream (\(streamId))")
        let nativeStream = createNativeStream(streamId: streamId)
        
        if let trackId = videoTrackId {
            Logger.debug(type: .nativePeerChannel,
                         message: "create native video track (\(trackId))")
            let videoSource = createNativeVideoSource()
            let videoTrack = createNativeVideoTrack(videoSource: videoSource,
                                                    trackId: trackId)
            nativeStream.addVideoTrack(videoTrack)
        }
        
        if let trackId = audioTrackId {
            Logger.debug(type: .nativePeerChannel,
                         message: "create native audio track (\(trackId))")
            let audioTrack = createNativeAudioTrack(trackId: trackId,
                                                    constraints: constraints.nativeValue)
            nativeStream.addAudioTrack(audioTrack)
        }
        
        return nativeStream
    }
    
    // クライアント情報としての Offer SDP を生成する
    func createClientOfferSDP(configuration: WebRTCConfiguration,
                              constraints: MediaConstraints,
                              handler: @escaping (String?, Error?) -> Void) {
        let peer = createNativePeerChannel(configuration: configuration, constraints: constraints, delegate: nil)
        let stream = createNativePublisherStream(streamId: "offer",
                                                 videoTrackId: "video",
                                                 audioTrackId: "audio",
                                                 constraints: constraints)
        peer.add(stream)
        peer.offer(for: constraints.nativeValue) { sdp, error in
            if let error = error {
                handler(nil, error)
            } else if let sdp = sdp {
                handler(sdp.sdp, nil)
            }
            peer.close()
        }
    }
    
}
