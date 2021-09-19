import WebRTC

public enum SoraDispatcher {

    /// カメラ用のキュー
    case camera

    /// 音声処理用のキュー
    case audio

    /// 指定されたキューを利用して、 block を非同期で実行します。
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
