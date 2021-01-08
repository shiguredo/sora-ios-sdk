import Foundation
import WebRTC

/**
 デバイスのカメラを利用した `VideoCapturer` のデフォルト実装です。
 `Configuration` の `videoCapturerDevice` に `CameraVideoCapturerDevice` を
 指定すると、この実装が映像キャプチャーとして使用されます。
 
 カメラはパブリッシャーまたはグループの接続時に自動的に起動 (起動済みなら再起動) されます。
 接続解除時は、 `Settings.canStop` が `true` であればカメラが停止されます。
 
 カメラの解像度とフレームレートは `CameraVideoCapturer.Settings` で指定可能です。
 ただし、カメラの起動中は設定を変更できません。
 カメラの設定を変更したい場合は、一旦カメラを停止 `stop()` してから
 `settings` プロパティに新しい設定をセットし、カメラを再起動 `start()` します。
 */
@available(iOSApplicationExtension, unavailable)
public final class CameraVideoCapturer: VideoCapturer {
    
    // MARK: インスタンスの取得
    
    /// シングルトンインスタンス
    public static var shared: CameraVideoCapturer = CameraVideoCapturer()
    
    /// :nodoc:
    public static var captureDevices: [AVCaptureDevice] {
        get { return RTCCameraVideoCapturer.captureDevices() }
    }
    
    /// :nodoc:
    public static func captureDevice(for position: CameraPosition) -> AVCaptureDevice? {
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
    public var handlers: VideoCapturerHandlers = VideoCapturerHandlers()
    
    /**
     カメラの設定
     
     カメラの設定を切り替える必要がある場合は、 `start()` を実行する前に設定してください。
     一旦 `start()` すると、一度 `stop()` して再度 `start()` するまで設定の変更は反映されません。
     */
    public var settings: CameraVideoCapturer.Settings = .default
    
    /// カメラの位置
    public var position: CameraPosition = .front {
        didSet {
            guard isRunning else { return }
            guard let current = currentCameraDevice else { return }
            
            Logger.debug(type: .cameraVideoCapturer,
                         message: "try change camera position")
            let session = nativeCameraVideoCapturer.captureSession
            let oldInputs = session.inputs
            for input in session.inputs {
                session.removeInput(input)
            }
            do {
                let newInput = try AVCaptureDeviceInput(device: current)
                if session.canAddInput(newInput) {
                    session.addInput(newInput)
                    Logger.debug(type: .cameraVideoCapturer,
                                 message: "did change camera position")
                    return
                }
            } catch let e {
                Logger.debug(type: .cameraVideoCapturer,
                             message: "failed change camera pasition (\(e.localizedDescription))")
            }

            Logger.debug(type: .cameraVideoCapturer,
                         message: "cannot add input device")
            for input in oldInputs {
                if session.canAddInput(input) {
                    session.addInput(input)
                } else {
                    Logger.debug(type: .cameraVideoCapturer,
                                 message: "failed revert input device \(input)")
                }
            }
        }
    }

    /// 使用中のカメラの位置に対応するデバイス
    public var currentCameraDevice: AVCaptureDevice? {
        get {
            switch position {
            case .front:
                return frontCameraDevice
            case .back:
                return backCameraDevice
            }
        }
    }
    
    private var nativeCameraVideoCapturer: RTCCameraVideoCapturer!
    private var frontCameraDevice: AVCaptureDevice?
    private var backCameraDevice: AVCaptureDevice?
    private var nativeDelegate: CameraVideoCapturerDelegate!
    
    init() {
        nativeDelegate = CameraVideoCapturerDelegate(cameraVideoCapturer: self)
        nativeCameraVideoCapturer = RTCCameraVideoCapturer(delegate: nativeDelegate)
        frontCameraDevice = CameraVideoCapturer.captureDevice(for: .front)
        backCameraDevice = CameraVideoCapturer.captureDevice(for: .back)
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
    public func start() {
        if isRunning {
            return
        }
        
        Logger.debug(type: .cameraVideoCapturer, message: "try start all devices with settings \(settings)")
        for device in RTCCameraVideoCapturer.captureDevices() {
            Logger.debug(type: .cameraVideoCapturer, message: "try start \(device) with settings \(settings)")
            guard let format = CameraVideoCapturer.suitableFormat(for: device, settings: settings) else {
                Logger.debug(type: .cameraVideoCapturer,
                             message: "    suitable format is not found")
                break
            }
            guard let fps = CameraVideoCapturer.suitableFrameRate(for: format, settings: settings) else {
                Logger.debug(type: .cameraVideoCapturer,
                             message: "    suitable frame rate is not found")
                break
            }

            nativeCameraVideoCapturer.startCapture(with: device, format: format, fps: fps)
            Logger.debug(type: .cameraVideoCapturer, message: "did start \(device) with \(format), \(fps)fps")
        }
        Logger.debug(type: .cameraVideoCapturer, message: "did start all devices")

        isRunning = true
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
    public func stop() {
        if isRunning {
            Logger.debug(type: .cameraVideoCapturer, message: "stop")
            nativeCameraVideoCapturer.stopCapture()
        }
        isRunning = false
    }
    
    /// カメラの位置を反転します。
    public func flip() {
        position = position.flip()
    }
    
}

// MARK: -

@available(iOSApplicationExtension, unavailable)
public extension CameraVideoCapturer {
    
    /**
     `CameraVideoCapturer` の設定を表すオブジェクトです。
     */
    struct Settings: CustomStringConvertible {
        
        /** デフォルトの設定。 */
        public static let `default` = Settings(
            resolution: .hd720p,
            frameRate: 30,
            canStop: true
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
        public let resolution: Resolution
        
        /**
         希望する映像フレームレート(Frames Per Second)。
         
         可能な限りここで指定された値が尊重されますが、
         例えばデバイス側が対応していない値が指定された場合などは、
         ここで指定された値と異なる値が実際には使用される事があります。
         */
        public let frameRate: Int
        
        /// `true` であれば接続解除時にカメラを停止します。
        public let canStop: Bool
        
        /// 文字列表現を返します。
        public var description: String {
            return "\(resolution), \(frameRate)fps"
        }

        /**
         初期化します。
         
         - parameter resolution: 解像度
         - parameter frameRate: フレームレート
         - parameter canStop: `true` であれば接続解除時にカメラを停止する
         */
        public init(resolution: Resolution, frameRate: Int, canStop: Bool) {
            self.resolution = resolution
            self.frameRate = frameRate
            self.canStop = canStop
        }
        
    }
    
}

// MARK: -

@available(iOSApplicationExtension, unavailable)
private class CameraVideoCapturerDelegate: NSObject, RTCVideoCapturerDelegate {
    
    weak var cameraVideoCapturer: CameraVideoCapturer!
    
    init(cameraVideoCapturer: CameraVideoCapturer) {
        self.cameraVideoCapturer = cameraVideoCapturer
    }
    
    func capturer(_ capturer: RTCVideoCapturer, didCapture nativeFrame: RTCVideoFrame) {
        let frame = VideoFrame.native(capturer: capturer, frame: nativeFrame)
        cameraVideoCapturer.stream?.send(videoFrame: frame)
        cameraVideoCapturer.handlers.onCapture?(frame)
    }
    
}

// MARK: -

/// :nodoc:
@available(iOSApplicationExtension, unavailable)
extension CameraVideoCapturer.Settings: Codable {
    
    enum CodingKeys: String, CodingKey {
        case resolution
        case frameRate
        case canStop
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resolution = try container.decode(Resolution.self, forKey: .resolution)
        frameRate = try container.decode(Int.self, forKey: .frameRate)
        canStop = try container.decode(Bool.self, forKey: .canStop)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(resolution, forKey: .resolution)
        try container.encode(frameRate, forKey: .frameRate)
        try container.encode(canStop, forKey: .canStop)
    }
    
}

@available(iOSApplicationExtension, unavailable)
private var resolutionTable: PairTable<String, CameraVideoCapturer.Settings.Resolution> =
    PairTable(name: "CameraVideoCapturer.Settings.Resolution",
              pairs: [("qvga240p", .qvga240p),
                      ("vga480p", .vga480p),
                      ("hd720p", .hd720p),
                      ("hd1080p", .hd1080p)])

/// :nodoc:
@available(iOSApplicationExtension, unavailable)
extension CameraVideoCapturer.Settings.Resolution: Codable {
    
    public init(from decoder: Decoder) throws {
        self = try resolutionTable.decode(from: decoder)
    }
    
    public func encode(to encoder: Encoder) throws {
        try resolutionTable.encode(self, to: encoder)
    }
    
}
