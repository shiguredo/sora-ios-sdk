import WebRTC

/// libwebrtc の内部で利用されているキューを表します。
public enum SoraDispatcher {

    static var peerConnectionQueue = DispatchQueue(label: "SoraDispatcher.peerConnection", qos: .utility)

    /// カメラ用のキュー
    case camera

    /// 音声処理用のキュー
    case audio

    // RTCPeerConnection 用のキュー
    case peerConnection

    /// 指定されたキューを利用して、 block を非同期で実行します。
    public static func async(on queue: SoraDispatcher, block: @escaping () -> Void) {
        let native: RTCDispatcherQueueType
        switch queue {
        case .camera:
            native = .typeCaptureSession
            RTCDispatcher.dispatchAsync(on: native, block: block)
        case .audio:
            native = .typeAudioSession
            RTCDispatcher.dispatchAsync(on: native, block: block)
        case .peerConnection:
            SoraDispatcher.peerConnectionQueue.async(execute: block)
        }
    }
}
