import WebRTC

public enum SoraDispatcher {

    /// カメラ用のキュー
    /// RTCDispatcherQueueType.typeCaptureSession に相当する
    case camera

    /// 音声処理用のキュー
    /// RTCDispatcherQueueType.typeAudioSession に相当する
    case audio

    /// RTCDispatcher を利用して、 block を非同期で実行する
    public static func async(on queue: SoraDispatcher, block: @escaping () -> Void) {
        let native: RTCDispatcherQueueType
        switch queue {
        case .camera:
            native = .typeCaptureSession
        case .audio:
            native = .typeAudioSession
        }
        RTCDispatcher.dispatchAsync(on: native, block: block)
    }

}
