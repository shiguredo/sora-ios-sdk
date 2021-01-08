import Foundation

/**
 デバイスのカメラを利用した `VideoCapturerDevice` です。

 `CameraVideoCapturerDevice` はストリームへの接続完了時、自動的にカメラを起動して映像のキャプチャと配信を開始します。
 またストリームから切断したタイミングで自動的にカメラキャプチャを終了します。

 自動的にカメラのハンドリングを行うため、複雑な用途が必要なく、すぐに使いたい場合に便利な `VideoCapturerDevice` です。
 */
public struct CameraVideoCapturerDevice: VideoCapturerDevice {
    let settings: CameraVideoCapturer.Settings

    public func stream(to stream: MediaStream) {
        // 接続処理と同時にデフォルトのCameraVideoCapturerを使用してキャプチャを開始する
        if CameraVideoCapturer.shared.isRunning {
            CameraVideoCapturer.shared.stop()
        }
        CameraVideoCapturer.shared.settings = settings
        CameraVideoCapturer.shared.start()
        stream.videoCapturer = CameraVideoCapturer.shared
    }

    public func terminate() {
        if settings.canStop {
            CameraVideoCapturer.shared.stop()
        }
    }
}
