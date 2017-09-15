import Foundation
import WebRTC

public enum SoraError: Error {
    case webSocketError(error: Error?,
        statusCode: WebSocketStatusCode?,
        reason: String?)
    case connectionTimeout
}

public class Sora {
    
    static var isInitialized: Bool = false
    
    public static func initialize() {
        RTCInitializeSSL()
        RTCEnableMetrics()
    }
    
    public static func finish() {
        RTCCleanupSSL()
    }
    
    public static var shared: Sora = {
        if !isInitialized {
            initialize()
            isInitialized = true
        }
        return Sora()
    }()
    
    public var webRTCInfo: WebRTCInfo? = WebRTCInfo.load()

    
    public init() {
        // TODO
    }
    
    public func connect(configuration: Configuration,
                        handler: @escaping (MediaChannel?, Error?) -> Void) {
        Log.debug(type: .sora, message: "connecting \(configuration.url.absoluteString)")
        let mediaChan = MediaChannel(configuration: configuration)
        mediaChan.connect { handler(mediaChan, $0) }
    }
    
}
