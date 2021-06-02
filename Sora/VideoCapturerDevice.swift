import Foundation

/**
 `Sora` の `Configuration` 内で使用するオプションです。
 
 `Configuration` 内で `videoEnabled` が有効になっている際に、初期値としてどの `VideoCapturer` が使用されるかを指定するオプションです。
  廃止されました。
 */
@available(*, unavailable, message: "VideoCapturerDevice は廃止されました。")
public enum VideoCapturerDevice {
    
    /**
     `CameraVideoCapturer` を `VideoCapturer` として使用します。
     
     このオプションが使用されている場合、 `Sora` はストリームへの接続完了時、自動的にカメラを起動して映像のキャプチャと配信を開始します。
     またこのオプションが使用されている場合、 `Sora` はストリームから切断したタイミングで自動的にカメラキャプチャを終了します。
     
     SDKが自動的にカメラのハンドリングを行うため、複雑な用途が必要なく、すぐに使いたい場合に便利なオプションです。
     */
    case camera(settings: CameraVideoCapturer.Settings)
    
    /**
     カスタムの実装を `VideoCapturer` として使用します。
     
     このオプションが使用されている場合、 `Sora` はストリームへの接続完了時に `VideoCapturer` を自動的に設定**しません**。
     したがってこのオプションを使用する場合は、ストリームへの接続完了後、自身でストリームの `VideoCapturer` を設定しない限り、映像は配信されません。
     またこのオプションが使用されている場合、 `Sora` はストリームから切断したタイミングに `VideoCapturer` を自動的に終了**しません**。
     必要に応じて終了時に `VideoCapturer` を停止する処理を忘れないようにしてください。
     
     以下のような場合にこのオプションを利用することをおすすめします。
     
     - カメラ以外の映像ソースから映像のキャプチャと配信を行いたいとき。
     - 映像のキャプチャ開始・終了タイミングを細かく調整したいとき。
     */
    case custom
    
}
