import Foundation
import WebRTC

public enum SoraError: Error {
    case webSocketError(error: Error?,
        statusCode: WebSocketStatusCode?,
        reason: String?)
    case connectionTimeout
}

public class Sora {
    
    private static let isInitialized: Bool = {
        initialize()
        return true
    }()
    
    private static func initialize() {
        Logger.debug(type: .sora, message: "initialize SDK")
        RTCInitializeSSL()
        RTCEnableMetrics()
    }
    
    public static func finish() {
        Logger.debug(type: .sora, message: "finish SDK")
        RTCShutdownInternalTracer()
        RTCCleanupSSL()
    }
    
    // MARK: - インスタンスの取得
    
    /// シングルトンインスタンス
    public static let shared: Sora = Sora()
    
    // MARK: - プロパティ
    
    // リンクしている WebRTC フレームワークの情報。
    // Sora iOS SDK が指定するバイナリでなければ ``nil`` 。
    public let webRTCInfo: WebRTCInfo? = WebRTCInfo.load()
    
    /**
     初期化します。
     */
    public init() {
        // This will guarantee that `Sora.initialize()` is called only once.
        // - It works even if user initialized `Sora` directly
        // - It works even if user directly use `Sora.shared`
        // - It guarantees `initialize()` is called only once thanks to the `static let` https://developer.apple.com/library/content/documentation/Swift/Conceptual/Swift_Programming_Language/Properties.html#//apple_ref/doc/uid/TP40014097-CH14-ID254
        let initialized = Sora.isInitialized
        // This looks silly, but this will ensure `Sora.isInitialized` is not be omitted,
        // no matter how clang optimizes compilation.
        // If we go for `let _ = Sora.isInitialized`, clang may omit this line,
        // which is fatal to the initialization logic.
        // The following line will NEVER fail.
        if !initialized { fatalError() }
    }
    
    /**
     Sora サーバーに接続します。
     
     - parameter configuration: クライアントの設定
     - parameter webRTCConfiguration: WebRTC の設定
     - parameter handler: 接続試行後に呼ばれるブロック。
     - parameter mediaChannel: (接続成功時のみ) メディアチャネル
     - parameter error: (接続失敗時のみ) エラー
     */
    public func connect(configuration: Configuration,
                        webRTCConfiguration: WebRTCConfiguration = WebRTCConfiguration(),
                        handler: @escaping (_ mediaChannel: MediaChannel?,
        _ error: Error?) -> Void) {
        Logger.debug(type: .sora, message: "connecting \(configuration.url.absoluteString)")
        let mediaChan = MediaChannel(configuration: configuration)
        mediaChan.connect(webRTCConfiguration: webRTCConfiguration) { error in
            if let error = error {
                handler(nil, error)
            } else {
                handler(mediaChan, nil)
            }
        }
    }
    
}
