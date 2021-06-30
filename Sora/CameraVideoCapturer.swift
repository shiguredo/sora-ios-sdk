import Foundation
import WebRTC

/**
 解像度やフレームレートなどの設定は `start` 実行時に指定します。
 カメラはパブリッシャーまたはグループの接続時に自動的に起動 (起動済みなら再起動) されます。

 カメラの設定を変更したい場合は、 `change` を実行します。
 */
public final class CameraVideoCapturer {
    
    // MARK: インスタンスの取得
    
    /// シングルトンインスタンス
    /// shared は廃止されました。
    @available(*, unavailable, message: "shared は廃止されました。")
    public static var shared: CameraVideoCapturer?
    
    /// 利用可能なデバイスのリスト
    /// 名称が devices に変更されました
    @available(*, unavailable, renamed: "devices")
    public static var captureDevices: [AVCaptureDevice] {
        get { return RTCCameraVideoCapturer.captureDevices() }
    }
 
    /// 利用可能なデバイスのリスト
    /// RTCCameraVideoCapturer.captureDevices を返す
    public static var devices: [AVCaptureDevice] {
        get { return RTCCameraVideoCapturer.captureDevices() }
    }
    
    /// 前面のカメラに対応するデバイス
    public private(set) static var front: CameraVideoCapturer = CameraVideoCapturer(device: device(for: .front) ?? nil)

    /// 背面のカメラに対応するデバイス
    public private(set) static var back: CameraVideoCapturer = CameraVideoCapturer(device: device(for: .back) ?? nil)

    /// 起動中のデバイス
    public private(set) static var current: CameraVideoCapturer?
    
    /// RTCCameraVideoCapturer が保持している AVCaptureSession
    public var captureSession: AVCaptureSession {
        get { return native.captureSession }
    }

    /// 指定したカメラ位置にマッチした最初のデバイスを返す
    /// 名称が device に変更されました
    @available(*, unavailable, renamed: "device")
    public static func captureDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        return nil
    }
    /// 指定したカメラ位置にマッチした最初のデバイスを返す
    /// captureDevice(for: .back) とすれば背面カメラを取得できる
    public static func device(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        for device in CameraVideoCapturer.devices {
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
    @available(*, unavailable, message: "suitableFormat は廃止されました。 format を利用してください。")
    public static func suitableFormat(for device: AVCaptureDevice, resolution: Any) -> AVCaptureDevice.Format? {
        return nil
    }
    
    /// 指定された設定に最も近い  AVCaptureDevice.Format? を返す
    public static func format(width: Int32, height: Int32, for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        var currentFormat: AVCaptureDevice.Format? = nil
        var currentDiff = INT_MAX
        for format in formats {
            let dimension = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let diff = abs(width - dimension.width) + abs(height - dimension.height)
            if diff < currentDiff {
                currentFormat = format
                currentDiff = diff
            }
        }
        return currentFormat
    }
    
    /// :nodoc:
    @available(*, unavailable, message: "suitableFrameRate は廃止されました。 maxFramerate を利用してください。")
    public static func suitableFrameRate(for format: AVCaptureDevice.Format, frameRate: Int) -> Int? {
        return nil
    }
    
    /// 指定された FPS 値をサポートしているレンジが存在すれば、その値を返す
    /// 存在しない場合はサポートされているレンジの中で最大の値を返す
    public static func maxFrameRate(_ frameRate: Int, for format: AVCaptureDevice.Format) -> Int? {
        if format.videoSupportedFrameRateRanges.contains(where: { Int($0.minFrameRate) <= frameRate && frameRate <= Int($0.maxFrameRate) }) {
            return frameRate
        }
        return format.videoSupportedFrameRateRanges
            .max { $0.maxFrameRate < $1.maxFrameRate }
            .map { Int($0.maxFrameRate) }
    }
    
    /// 引数に指定された capturer を停止し、反対の position を持つ CameraVideoCapturer を起動します
    /// 起動に成功した場合は、 capturer の保持していた MediaStream に CameraVideoCapturer がセットされます
    public static func flip(_ capturer: CameraVideoCapturer, completionHandler: @escaping ((Error?) -> Void)) {
        guard capturer.device != nil else {
            completionHandler(SoraError.cameraError(reason: "device should not be nil"))
            return
        }
        
        guard capturer.format != nil else {
            completionHandler(SoraError.cameraError(reason: "format should not be nil"))
            return
        }
        
        // 反対の position を持つ CameraVideoCapturer を取得する
        let flip: CameraVideoCapturer = capturer.device!.position == .front ? .back : .front
        
        let dimension = CMVideoFormatDescriptionGetDimensions(capturer.format!.formatDescription)
        guard let format = CameraVideoCapturer.format(width: dimension.width,
                                                      height: dimension.height,
                                                      for: flip.device!) else {
            completionHandler(SoraError.cameraError(reason: "CameraVideoCapturer.format failed: suitable format is not found"))
            return
        }
        
        guard let frameRate = CameraVideoCapturer.maxFrameRate(capturer.frameRate!, for: format) else {
            completionHandler(SoraError.cameraError(reason: "CameraVideoCapturer.maxFramerate failed: suitable frameRate is not found"))
            return
        }
        
        guard let stream = capturer.stream else {
            completionHandler(SoraError.cameraError(reason: "stream should not be nil"))
            return
        }
        
        capturer.stop { error in
            guard error == nil else {
                print("\(String(describing: error))")
                completionHandler(SoraError.cameraError(reason: "CameraVideoCapturer.stop failed"))
                return
            }
            flip.start(format: format, frameRate: frameRate) { error in
                guard error == nil else {
                    completionHandler(SoraError.cameraError(reason: "CameraVideoCapturer.start failed"))
                    return
                }
                stream.cameraVideoCapturer = flip
                completionHandler(nil)
            }
        }
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
    public private(set) var settings: Any?
    
    /// カメラの位置
    @available(*, unavailable, message: "position は廃止されました。 現在利用されているデバイスは CameraVideoCapturer.current?.device?.position で取得してください。")
    public var position: AVCaptureDevice.Position? = nil

    /// 使用中のカメラの位置に対応するデバイス
    /// captureDevice に変更されました
    @available(*, deprecated, renamed: "captureDevice")
    public var currentCameraDevice: AVCaptureDevice? {
        get {
            device
        }
    }
    
    // 使用中のデバイス
    public var device: AVCaptureDevice?
    
    /// フレームレート
    public private(set) var frameRate: Int?
    
    /// `true` であれば接続解除時にカメラを停止します。
    @available(*, unavailable, message: "stopWhenDone は廃止されました。")
    public private(set) var stopWhenDone: Bool = false
    
    /// フォーマット
    public private(set) var format: AVCaptureDevice.Format?
    
    private var native: RTCCameraVideoCapturer!
    private var nativeDelegate: CameraVideoCapturerDelegate!
    
    public init(device: AVCaptureDevice?) {
        self.device = device
        nativeDelegate = CameraVideoCapturerDelegate(cameraVideoCapturer: self)
        native = RTCCameraVideoCapturer(delegate: nativeDelegate)
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
    public func start(format: AVCaptureDevice.Format,
                      frameRate: Int,
                      completionHandler: @escaping ((Error?) -> Void)) {
        guard isRunning == false else {
            completionHandler(SoraError.cameraError(reason: "isRunning should be false"))
            return
        }
        
        guard let device = device else {
            completionHandler(SoraError.cameraError(reason: "device is not initialized"))
            return
        }
        
        native.startCapture(with: device,
                            format: format,
                            fps: frameRate) { [self] (error: Error?) in
            guard error == nil else {
                completionHandler(error)
                return
            }
            Logger.debug(type: .cameraVideoCapturer, message: "succeeded to start \(device) with \(format), \(frameRate)fps")
            
            // start が成功した際の処理
            self.format = format
            self.frameRate = frameRate
            isRunning = true
            CameraVideoCapturer.current = self
            completionHandler(nil)
            handlers.onStart?()
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
            completionHandler(SoraError.cameraError(reason: "isRunning should be true"))
            return
        }
        
        native.stopCapture() { [self] in
            Logger.debug(type: .cameraVideoCapturer, message: "succeeded to stop \(String(describing: device))")
            
            // stop が成功した際の処理
            isRunning = false
            CameraVideoCapturer.current = nil
            completionHandler(nil)
            handlers.onStop?()
        }
    }
    
    /// カメラを再起動します
    public func restart(completionHandler: @escaping ((Error?) -> Void)) {
        guard isRunning else {
            completionHandler(SoraError.cameraError(reason: "isRunning should be true"))
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

            start(format: format,
                  frameRate: frameRate) { (error: Error?) in
                guard error == nil else {
                    completionHandler(error)
                    return
                }
                
                Logger.debug(type: .cameraVideoCapturer, message: "succeeded to restart")
                completionHandler(nil)
            }
        }
    }

    /// カメラを停止後、指定されたパラメーターで起動します
    public func change(format: AVCaptureDevice.Format? = nil, frameRate: Int? = nil, completionHandler: @escaping ((Error?) -> Void)) {
        guard isRunning else {
            completionHandler(SoraError.cameraError(reason: "isRunning should be true"))
            return
        }
        
        guard let format = (format ?? self.format) else {
            completionHandler(SoraError.cameraError(reason: "failed to access format"))
            return
        }
        
        guard let frameRate = (frameRate ?? self.frameRate) else {
            completionHandler(SoraError.cameraError(reason: "failed to access frame rate"))
            return
        }
        
        stop() { [self] (error: Error?) in
            guard error == nil else {
                completionHandler(error)
                return
            }

            start(format: format, frameRate: frameRate) { (error: Error?) in
                guard error == nil else {
                    completionHandler(error)
                    return
                }
                
                Logger.debug(type: .cameraVideoCapturer, message: "succeeded to change")
                completionHandler(nil)
            }
        }
    }
}

// MARK: -

/**
 `CameraVideoCapturer` の設定を表すオブジェクトです。
 */
public struct CameraSettings: CustomStringConvertible {
    
    /** デフォルトの設定。 */
    public static let `default` = CameraSettings()
    
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
    /// 廃止されました。
    @available(*, unavailable, message: "廃止されました")
    public var canStop: Bool = false
    
    /// カメラの位置
    public var position: AVCaptureDevice.Position
    
    /// カメラ起動の有無
    public var isEnabled: Bool
    
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
    public init(resolution: Resolution = .hd720p, frameRate: Int = 30, position: AVCaptureDevice.Position = .front, isEnabled: Bool = true) {
        self.resolution = resolution
        self.frameRate = frameRate
        self.position = position
        self.isEnabled = isEnabled
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

private var resolutionTable: PairTable<String, CameraSettings.Resolution> =
    PairTable(name: "CameraVideoCapturer.Settings.Resolution",
              pairs: [("qvga240p", .qvga240p),
                      ("vga480p", .vga480p),
                      ("hd720p", .hd720p),
                      ("hd1080p", .hd1080p)])

/// :nodoc:
extension CameraSettings.Resolution: Codable {
    
    public init(from decoder: Decoder) throws {
        self = try resolutionTable.decode(from: decoder)
    }
    
    public func encode(to encoder: Encoder) throws {
        try resolutionTable.encode(self, to: encoder)
    }
    
}
