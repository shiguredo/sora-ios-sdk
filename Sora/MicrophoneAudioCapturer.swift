import AVKit
import WebRTC

public final class MicrophoneAudioCapturer {
    static var shared: MicrophoneAudioCapturer = MicrophoneAudioCapturer()
    
    public var isAudioInputInitialized: Bool = false
    
    private var audioSession: AVAudioSession {
        get {
            return native.session
        }
    }
    
    public var isActive: Bool? {
        get {
            return native.isActive
        }
    }
    
    public var native: RTCAudioSession {
        get {
            RTCAudioSession.sharedInstance()
        }
    }

    public func activate(completionHandler: @escaping (Error?) -> Void) {
        // TODO: mode が playAndRecord 出ない場合はエラーにした方が良い?
        
        // 音声入力の初期化
        if isAudioInputInitialized {
            Logger.debug(type: .peerChannel, // TODO: Logger の type は全体的に見直しが必要
                         message: "audio input is already initialized")
        } else {
            Logger.debug(type: .peerChannel,
                         message: "initialize audio input")
            MicrophoneAudioCapturer.shared.native.initializeInput() { error in
                guard error == nil else {
                    completionHandler(SoraError.audioCapturerError(reason: "failed to initialize audio input => \(String(describing: error?.localizedDescription))"))
                    return
                }
    
                self.isAudioInputInitialized = true
                Logger.debug(type: .peerChannel,
                             message: "audio input is initialized => category \(RTCAudioSession.sharedInstance().category)")
            }
        }

        do {
            try native.setActive(true)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
    
    public func deactivate(completionHandler: (Error?) -> Void) {
        do {
            try native.setActive(false)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
        
    }
    
    public func configure(block: () -> Void) {
        native.lockForConfiguration()
        block()
        native.unlockForConfiguration()
    }
    
    // TODO: addHandlers, removeHandlers
    
    init() {
        RTCAudioSession.sharedInstance().useManualAudio = false // TODO: ここで良いのか?
    }
}

// TODO: MicrophoneSettings => AudioSettings への rename を検討する
// その場合は isEnabled も併せて変更する (isEnabled => isMicEnabled)
public struct MicrophoneSettings {
    public var isEnabled = true
    public var mode: AVAudioSession.Mode = .videoChat
    public var category: AVAudioSession.Category = .playAndRecord
    public var options: AVAudioSession.CategoryOptions? = [.allowBluetooth, .allowBluetoothA2DP, .allowAirPlay]
    public var outputPort: AVAudioSession.PortOverride = .none
}
