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
        RTCInitializeSSL()
        RTCEnableMetrics()
    }
    
    public static func finish() {
        RTCCleanupSSL()
    }
    
    public static let shared: Sora = Sora()
    
    // TODO: This is most likely can be non-optional value: `load()` only returns `nil` when the bundle is severly broken
    public let webRTCInfo: WebRTCInfo? = WebRTCInfo.load()
    
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
    
    public func connect(configuration: Configuration,
                        webRTCConfiguration: WebRTCConfiguration = WebRTCConfiguration(),
                        handler: @escaping (MediaChannel?, Error?) -> Void) {
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
