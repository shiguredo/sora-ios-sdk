import Foundation
import WebRTC

/**
 デバイスのカメラを利用した `VideoCapturer` のデフォルト実装です。
 解像度やフレームレートなどの設定は `start` 実行時に指定します。

 カメラはパブリッシャーまたはグループの接続時に自動的に起動 (起動済みなら再起動) されます。
 接続解除時は、 `stopWhenDone` が `true` であればカメラが停止されます。

 カメラの設定を変更したい場合は、 `changeSettings` を実行します。
 */
public final class CameraVideoCapturer: VideoCapturer {
    
    // MARK: インスタンスの取得
    
    /// シングルトンインスタンス
    public static var shared: CameraVideoCapturer = CameraVideoCapturer()
    
    /// 利用可能なデバイスのリスト
    /// RTCCameraVideoCapturer.captureDevices を返す
    public static var captureDevices: [AVCaptureDevice] {
        get { return RTCCameraVideoCapturer.captureDevices() }
    }
    
    /// RTCCameraVideoCapturer が保持している AVCaptureSession
    public var captureSession: AVCaptureSession {
        get { return nativeCameraVideoCapturer.captureSession }
    }

    /// 指定したカメラ位置にマッチした最初のデバイスを返す
    /// captureDevice(for: .back) とすれば背面カメラを取得できる
    public static func captureDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        for device in CameraVideoCapturer.captureDevices {
            switch (device.position, position) {
            case (.front, .front), (.back, .back):
                return device
            default:
                break
            }
        }
        return nil
    }
    
    /// :nodoc:
    public static func suitableFormat(for device: AVCaptureDevice, settings: CameraVideoCapturer.Settings) -> AVCaptureDevice.Format? {
        // 利用できる全フォーマットのうち、最も指定された設定の値に近いものを使用します。
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        var currentFormat: AVCaptureDevice.Format? = nil
        var currentDiff = INT_MAX
        for format in formats {
            let dimension = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let diff = abs(settings.resolution.width - dimension.width) + abs(settings.resolution.height - dimension.height)
            if diff < currentDiff {
                currentFormat = format
                currentDiff = diff
            }
        }
        return currentFormat
    }
    
    /// :nodoc:
    public static func suitableFrameRate(for format: AVCaptureDevice.Format, settings: CameraVideoCapturer.Settings) -> Int? {
        // 設定で指定されたFPS値をサポートしているレンジが一つでも存在すれば、その設定の値を使用する。
        // 一つも見つからなかった場合はサポートされているレンジの中で最も大きなFPS値を使用する。
        if format.videoSupportedFrameRateRanges.contains(where: { Int($0.minFrameRate) <= settings.frameRate && settings.frameRate <= Int($0.maxFrameRate) }) {
            return settings.frameRate
        }
        return format.videoSupportedFrameRateRanges
            .max { $0.maxFrameRate < $1.maxFrameRate }
            .map { Int($0.maxFrameRate) }
    }
    
    // MARK: プロパティ
    
    /// 出力先のストリーム
    public var stream: MediaStream?
    
    /// カメラが起動中であれば ``true``
    public private(set) var isRunning: Bool = false
    
    /// イベントハンドラ
    public var handlers: CameraVideoCapturerHandlers = CameraVideoCapturerHandlers()
    
    /// カメラの設定
    /// 廃止されました
    @available(*, unavailable, message: "settings は廃止されました。")
    public private(set) var settings: CameraVideoCapturer.Settings = .default
    
    /// カメラの位置
    @available(*, unavailable, message: "position は廃止されました。")
    public var position: AVCaptureDevice.Position = .front

    /// 使用中のカメラの位置に対応するデバイス
    /// captureDevice に変更されました
    @available(*, deprecated, renamed: "captureDevice")
    public var currentCameraDevice: AVCaptureDevice? {
        get {
            captureDevice
        }
    }
    
    // 使用中のデバイス
    public private(set) var captureDevice: AVCaptureDevice?
    
    /// フレームレート
    public private(set) var frameRate: Int?
    
    /// `true` であれば接続解除時にカメラを停止します。
    public private(set) var stopWhenDone: Bool = false
    
    /// フォーマット
    public private(set) var format: AVCaptureDevice.Format?
    
    private var nativeCameraVideoCapturer: RTCCameraVideoCapturer!
    private var nativeDelegate: CameraVideoCapturerDelegate!
    
    public init() {
        nativeDelegate = CameraVideoCapturerDelegate(cameraVideoCapturer: self)
        nativeCameraVideoCapturer = RTCCameraVideoCapturer(delegate: nativeDelegate)
    }
    
    // MARK: カメラの操作
    

    /**
     * カメラを起動します。
     *
     * このメソッドを実行すると、 `UIDevice` の
     * `beginGeneratingDeviceOrientationNotifications()` が実行されます。
     * `beginGeneratingDeviceOrientationNotifications()` または
     * `endGeneratingDeviceOrientationNotifications()` を使う際は
     * 必ず対に実行するように注意してください。
     */
    public func start(with device: AVCaptureDevice,
                      settings: CameraVideoCapturer.Settings,
                      completionHandler: @escaping ((Error?) -> Void)) {
        guard !isRunning else {
            completionHandler(CameraVideoCapturer.unexpectedIsRunningError(action: "start", isRunning: isRunning))
            return
        }
        
        guard let format = CameraVideoCapturer.suitableFormat(for: device, settings: settings) else {
            completionHandler(SoraError.cameraError(reason: "suitable format is not found"))
            return
        }
        guard let frameRate = CameraVideoCapturer.suitableFrameRate(for: format, settings: settings) else {
            completionHandler(SoraError.cameraError(reason: "suitable frame rate is not found"))
            return
        }
        
        start(with: device,
              format: format,
              frameRate: frameRate,
              stopWhenDone: settings.stopWhenDone,
              completionHandler: completionHandler)
    }
    
    public func start(with device: AVCaptureDevice,
                      format: AVCaptureDevice.Format,
                      frameRate: Int, stopWhenDone: Bool,
                      completionHandler: @escaping ((Error?) -> Void)) {
        guard !isRunning else {
            completionHandler(CameraVideoCapturer.unexpectedIsRunningError(action: "start", isRunning: isRunning))
            return
        }
        
        nativeCameraVideoCapturer.startCapture(with: device,
                                               format: format,
                                               fps: frameRate) { [self] (error: Error?) in
            guard error == nil else {
                completionHandler(error)
                return
            }
            Logger.debug(type: .cameraVideoCapturer, message: "succeeded to start \(device) with \(format), \(frameRate)fps")
            
            // start が成功した際の処理
            isRunning = true
            captureDevice = device
            self.format = format
            self.frameRate = frameRate
            self.stopWhenDone = stopWhenDone
            handlers.onStart?()
            completionHandler(nil)
        }
    }
    
    /**
     * カメラを停止します。
     *
     * このメソッドを実行すると、 `UIDevice` の
     * `endGeneratingDeviceOrientationNotifications()` が実行されます。
     * `beginGeneratingDeviceOrientationNotifications()` または
     * `endGeneratingDeviceOrientationNotifications()` を使う際は
     * 必ず対に実行するように注意してください。
     */
    public func stop(completionHandler: @escaping ((Error?) -> Void)) {
        guard isRunning else {
            completionHandler(CameraVideoCapturer.unexpectedIsRunningError(action: "stop", isRunning: isRunning))
            return
        }
        
        nativeCameraVideoCapturer.stopCapture() { [self] in
            Logger.debug(type: .cameraVideoCapturer, message: "succeeded to stop \(String(describing: captureDevice))")
            
            // stop が成功した際の処理
            isRunning = false
            handlers.onStop?()
            completionHandler(nil)
        }
    }
    
    public func restart(completionHandler: @escaping ((Error?) -> Void)) {
        guard isRunning else {
            completionHandler(CameraVideoCapturer.unexpectedIsRunningError(action: "restart", isRunning: isRunning))
            return
        }
        guard let device = captureDevice else {
            completionHandler(SoraError.cameraError(reason: "failed to access captureDevice"))
            return
        }
        
        guard let format = self.format else {
            completionHandler(SoraError.cameraError(reason: "failed to access format"))
            return
        }
        
        guard let frameRate = self.frameRate else {
            completionHandler(SoraError.cameraError(reason: "failed to access frame rate"))
            return
        }
        
        stop() { [self] (error: Error?) in
            guard error == nil else {
                completionHandler(error)
                return
            }

            start(with: device,
                  format: format,
                  frameRate: frameRate,
                  stopWhenDone: stopWhenDone) { (error: Error?) in
                guard error == nil else {
                    completionHandler(error)
                    return
                }
                
                Logger.debug(type: .cameraVideoCapturer, message: "succeeded to restart")
                completionHandler(nil)
            }
        }
    }
    
    public func changeSettings(with device: AVCaptureDevice,
                               format: AVCaptureDevice.Format,
                               frameRate: Int,
                               stopWhenDone: Bool,
                               completionHandler: @escaping ((Error?) -> Void)) {
        if isRunning {
            stop() { [self] (error: Error?) in
                guard error == nil else {
                    completionHandler(error)
                    return
                }
                start(with: device,
                      format: format,
                      frameRate: frameRate,
                      stopWhenDone: stopWhenDone) { (error: Error?) in
                    guard error == nil else {
                        completionHandler(error)
                        return
                    }
                    Logger.debug(type: .cameraVideoCapturer, message: "succeeded to changeSettings")
                    completionHandler(nil)
                }
            }
        }
    }

    // カメラの前面と背面を切り替える
    // - カメラが起動していなければエラー (SoraError.cameraError)
    // - Settings.flip を使い、カメラの位置を切り替えた Settings を取得する
    // - その Settings を changeSettings() に渡せばよい
    public func flip(completionHandler: @escaping ((Error?) -> Void)) {
        guard isRunning else {
            completionHandler(CameraVideoCapturer.unexpectedIsRunningError(action: "flip", isRunning:isRunning))
            return
        }

        guard let format = self.format else {
            completionHandler(SoraError.cameraError(reason: "failed to access format"))
            return
        }
        guard let frameRate = self.frameRate else {
            completionHandler(SoraError.cameraError(reason: "failed to access frameRate"))
            return
        }
        guard let position = captureDevice?.position else {
            completionHandler(SoraError.cameraError(reason: "failed to access captureDevice.position"))
            return
        }
        
        let flippedPosition: AVCaptureDevice.Position = (position == .front) ? .back : .front
        guard let device = CameraVideoCapturer.captureDevice(for: flippedPosition) else {
            completionHandler(SoraError.cameraError(reason: "device is not found"))
            return
        }

        changeSettings(with: device,
                       format: format,
                       frameRate: frameRate,
                       stopWhenDone: stopWhenDone) {
            (error: Error?) in
            guard error == nil else {
                completionHandler(error)
                return
            }
            Logger.debug(type: .cameraVideoCapturer, message: "succeeded to flip")
            completionHandler(nil)
        }
    }
    
    private static func unexpectedIsRunningError(action: String, isRunning: Bool) -> SoraError {
        return SoraError.cameraError(reason: "tried to \(action) but isRunning is unexpected value: isRunning => \(isRunning)")
    }
}

// MARK: -

public extension CameraVideoCapturer {
    
    /**
     `CameraVideoCapturer` の設定を表すオブジェクトです。
     */
    struct Settings: CustomStringConvertible {
        
        /** デフォルトの設定。 */
        public static let `default` = Settings(
            resolution: .hd720p,
            frameRate: 30,
            stopWhenDone: true,
            position: .front
        )
        
        /**
         `CameraVideoCapturer` で使用する映像解像度を表すenumです。
         */
        public enum Resolution {
            
            /// QVGA, 320x240
            case qvga240p
            
            /// VGA, 640x480
            case vga480p
            
            /// HD 720p, 1280x720
            case hd720p
            
            /// HD 1080p, 1920x1080
            case hd1080p
            
            /// 横方向のピクセル数を返します。
            public var width: Int32 {
                switch self {
                case .qvga240p: return 320
                case .vga480p: return 640
                case .hd720p: return 1280
                case .hd1080p: return 1920
                }
            }
            
            /// 縦方向のピクセル数を返します。
            public var height: Int32 {
                switch self {
                case .qvga240p: return 240
                case .vga480p: return 480
                case .hd720p: return 720
                case .hd1080p: return 1080
                }
            }
            
        }
        
        /**
         希望する映像解像度。
         
         可能な限りここで指定された値が尊重されますが、
         例えばデバイス側が対応していない値が指定された場合などは、
         ここで指定された値と異なる値が実際には使用される事があります。
         */
        public var resolution: Resolution
        
        /**
         希望する映像フレームレート(Frames Per Second)。
         
         可能な限りここで指定された値が尊重されますが、
         例えばデバイス側が対応していない値が指定された場合などは、
         ここで指定された値と異なる値が実際には使用される事があります。
         */
        public var frameRate: Int
        
        /// `true` であれば接続解除時にカメラを停止します。
        /// stopWhenDone に変更されました。
        @available(*, deprecated, renamed: "stopWhenDone")
        public var canStop: Bool {
            get { stopWhenDone }
            set { stopWhenDone = newValue }
        }
        
        /// `true` であれば接続解除時にカメラを停止します。
        public var stopWhenDone: Bool
        
        /// カメラの位置
        public var position: AVCaptureDevice.Position
        
        /// 文字列表現を返します。
        public var description: String {
            return "\(resolution), \(frameRate)fps"
        }

        /**
         初期化します。
         
         - parameter resolution: 解像度
         - parameter frameRate: フレームレート
         - parameter stopWhenDone: `true` であれば接続解除時にカメラを停止する
         */
        public init(resolution: Resolution, frameRate: Int, stopWhenDone: Bool, position: AVCaptureDevice.Position) {
            self.resolution = resolution
            self.frameRate = frameRate
            self.stopWhenDone = stopWhenDone
            self.position = position
        }
        
    }
    
}

// MARK: -

private class CameraVideoCapturerDelegate: NSObject, RTCVideoCapturerDelegate {
    
    weak var cameraVideoCapturer: CameraVideoCapturer!
    
    init(cameraVideoCapturer: CameraVideoCapturer) {
        self.cameraVideoCapturer = cameraVideoCapturer
    }
    
    func capturer(_ capturer: RTCVideoCapturer, didCapture nativeFrame: RTCVideoFrame) {
        let frame = VideoFrame.native(capturer: capturer, frame: nativeFrame)
        if let editedFrame = cameraVideoCapturer.handlers.onCapture?(frame) {
            cameraVideoCapturer.stream?.send(videoFrame: editedFrame)
        } else {
            cameraVideoCapturer.stream?.send(videoFrame: frame)
        }
    }
    
}

// MARK: -

private var resolutionTable: PairTable<String, CameraVideoCapturer.Settings.Resolution> =
    PairTable(name: "CameraVideoCapturer.Settings.Resolution",
              pairs: [("qvga240p", .qvga240p),
                      ("vga480p", .vga480p),
                      ("hd720p", .hd720p),
                      ("hd1080p", .hd1080p)])

/// :nodoc:
extension CameraVideoCapturer.Settings.Resolution: Codable {
    
    public init(from decoder: Decoder) throws {
        self = try resolutionTable.decode(from: decoder)
    }
    
    public func encode(to encoder: Encoder) throws {
        try resolutionTable.encode(self, to: encoder)
    }
    
}
