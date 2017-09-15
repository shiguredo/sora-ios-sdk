import Foundation
import WebRTC
import SocketRocket

open class WebSocketEventHandlers {

    var onOpenHandler: ((SRWebSocket) -> ())?
    var onFailureHandler: ((SRWebSocket, Error) -> ())?
    var onPongHandler: ((SRWebSocket, Data) -> ())?
    var onMessageHandler: ((SRWebSocket, AnyObject) -> ())?
    var onCloseHandler: ((SRWebSocket, Int, String?, Bool) -> ())?

    public init() {}
    
    public func onOpen(handler: @escaping (SRWebSocket) -> ()) {
        onOpenHandler = handler
    }
    
    public func onFailure(handler: @escaping (SRWebSocket, Error) -> ()) {
        onFailureHandler = handler
    }
    
    public func onPong(handler: @escaping (SRWebSocket, Data) -> ()) {
        onPongHandler = handler
    }
    
    public func onMessage(handler: @escaping (SRWebSocket, AnyObject) -> ()) {
        onMessageHandler = handler
    }
    
    public func onClose(handler: @escaping (SRWebSocket, Int, String?, Bool) -> ()) {
        onCloseHandler = handler
    }
    
}

open class SignalingEventHandlers {
    
    var onReceiveHandler: ((Message) -> Void)?
    var onConnectHandler: ((Void) -> Void)?
    var onDisconnectHandler: ((Void) -> Void)?
    var onFailureHandler: ((ConnectionError) -> Void)?
    var onPingHandler: ((Void) -> Void)?

    public init() {}

    public func onReceive(handler: @escaping ((Message) -> Void)) {
        onReceiveHandler = handler
    }
    
    public func onConnect(handler: @escaping ((Void) -> Void)) {
        onConnectHandler = handler
    }
    
    public func onDisconnect(handler: @escaping ((Void) -> Void)) {
        onDisconnectHandler = handler
    }
    
    public func onFailure(handler: @escaping ((ConnectionError) -> Void)) {
        onFailureHandler = handler
    }
    
    public func onPing(handler: @escaping ((Void) -> Void)) {
        onPingHandler = handler
    }
    
}

open class PeerConnectionEventHandlers {
    
    var onConnectHandler: ((RTCPeerConnection) -> Void)?
    var onDisconnectHandler: ((RTCPeerConnection) -> Void)?
    var onFailureHandler: ((RTCPeerConnection, Error) -> Void)?
    var onChangeSignalingStateHandler:
    ((RTCPeerConnection, RTCSignalingState) -> Void)?
    var onAddStreamHandler: ((RTCPeerConnection, RTCMediaStream) -> Void)?
    var onRemoveStreamHandler: ((RTCPeerConnection, RTCMediaStream) -> Void)?
    var onNegotiateHandler: ((RTCPeerConnection) -> Void)?
    var onChangeIceConnectionState:
    ((RTCPeerConnection,  RTCIceConnectionState) -> Void)?
    var onChangeIceConnectionStateHandler:
    ((RTCPeerConnection,  RTCIceConnectionState) -> Void)?
    var onChangeIceGatheringStateHandler:
    ((RTCPeerConnection, RTCIceGatheringState) -> Void)?
    var onGenerateIceCandidateHandler:
    ((RTCPeerConnection, RTCIceCandidate) -> Void)?
    var onRemoveCandidatesHandler:
    ((RTCPeerConnection, [RTCIceCandidate]) -> Void)?
    
    public init() {}

    public func onConnect(handler: @escaping ((RTCPeerConnection) -> Void)) {
        onConnectHandler = handler
    }
    
    public func onDisconnect(handler: @escaping ((RTCPeerConnection) -> Void)) {
        onDisconnectHandler = handler
    }

    public func onFailure(handler: @escaping ((RTCPeerConnection, Error) -> Void)) {
        onFailureHandler = handler
    }
    
    public func onChangeSignalingState(handler:
        @escaping (RTCPeerConnection, RTCSignalingState) -> Void) {
        onChangeSignalingStateHandler = handler
    }
    
    public func onAddStream(handler:
        @escaping (RTCPeerConnection, RTCMediaStream) -> Void) {
        onAddStreamHandler = handler
    }
    
    public func onRemoveStream(handler:
        @escaping (RTCPeerConnection, RTCMediaStream) -> Void) {
        onRemoveStreamHandler = handler
    }
    
    public func onNegotiate(handler: @escaping (RTCPeerConnection) -> Void) {
        onNegotiateHandler = handler
    }
    
    public func onChangeIceConnectionState(handler:
        @escaping (RTCPeerConnection,  RTCIceConnectionState) -> Void) {
        onChangeIceConnectionStateHandler = handler
    }
    
    public func onChangeIceGatheringState(handler:
        @escaping (RTCPeerConnection, RTCIceGatheringState) -> Void) {
        onChangeIceGatheringStateHandler = handler
    }
    
    public func onGenerateIceCandidate(handler:
        @escaping (RTCPeerConnection, RTCIceCandidate) -> Void) {
        onGenerateIceCandidateHandler = handler
    }
    
    public func onRemoveCandidates(handler:
        @escaping (RTCPeerConnection, [RTCIceCandidate]) -> Void) {
        onRemoveCandidatesHandler = handler
    }

}
