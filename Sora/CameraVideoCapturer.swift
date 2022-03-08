import Foundation
import WebRTC

/**
 解像度やフレームレートなどの設定は `start` 実行時に指定します。
 カメラはパブリッシャーまたはグループの接続時に自動的に起動 (起動済みなら再起動) されます。

 カメラの設定を変更したい場合は、 `change` を実行します。
 */
public final class CameraVideoCapturer {
    // MARK: インスタンスの取得

    /// 利用可能なデバイスのリスト
    /// RTCCameraVideoCapturer.captureDevices を返します。
    public static var devices: [AVCaptureDevice] { RTCCameraVideoCapturer.captureDevices() }

    /// 前面のカメラに対応するデバイス
    public private(set) static var front: CameraVideoCapturer? = {
        if let device = device(for: .front) {
            return CameraVideoCapturer(device: device)
        } else {
            return nil
        }
    }()

    /// 背面のカメラに対応するデバイス
    public private(set) static var back: CameraVideoCapturer? = {
        if let device = device(for: .back) {
            return CameraVideoCapturer(device: device)
        } else {
            return nil
        }
    }()

    /// 起動中のデバイス
    public private(set) static var current: CameraVideoCapturer?

    /// RTCCameraVideoCapturer が保持している AVCaptureSession
    public var captureSession: AVCaptureSession { native.captureSession }

    /// 指定したカメラ位置にマッチした最初のデバイスを返します。
    /// captureDevice(for: .back) とすれば背面カメラを取得できます。
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

    /// 指定された設定に最も近い  AVCaptureDevice.Format? を返します。
    public static func format(width: Int32, height: Int32, for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        var currentFormat: AVCaptureDevice.Format?
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

    /// 指定された FPS 値をサポートしているレンジが存在すれば、その値を返します。
    /// 存在しない場合はサポートされているレンジの中で最大の値を返します。
    public static func maxFrameRate(_ frameRate: Int, for format: AVCaptureDevice.Format) -> Int? {
        if format.videoSupportedFrameRateRanges.contains(where: { Int($0.minFrameRate) <= frameRate && frameRate <= Int($0.maxFrameRate) }) {
            return frameRate
        }
        return format.videoSupportedFrameRateRanges
            .max { $0.maxFrameRate < $1.maxFrameRate }
            .map { Int($0.maxFrameRate) }
    }

    /// 引数に指定された capturer を停止し、反対の position を持つ CameraVideoCapturer を起動します。
    /// CameraVideoCapturer の起動には、 capturer と近い設定のフォーマットとフレームレートが利用されます。
    /// また、起動された CameraVideoCapturer には capturer の保持する MediaStream が設定されます。
    public static func flip(_ capturer: CameraVideoCapturer, completionHandler: @escaping ((Error?) -> Void)) {
        guard let format = capturer.format else {
            completionHandler(SoraError.cameraError(reason: "format should not be nil"))
            return
        }

        // 反対の position を持つ CameraVideoCapturer を取得します。
        guard let flip: CameraVideoCapturer = (capturer.device.position == .front ? .back : .front) else {
            let name = capturer.device.position == .front ? "back" : "front"
            completionHandler(SoraError.cameraError(reason: "\(name) camera is not found"))
            return
        }

        let dimension = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        guard let format = CameraVideoCapturer.format(width: dimension.width,
                                                      height: dimension.height,
                                                      for: flip.device)
        else {
            completionHandler(SoraError.cameraError(reason: "CameraVideoCapturer.format failed: suitable format is not found"))
            return
        }

        guard let frameRate = CameraVideoCapturer.maxFrameRate(capturer.frameRate!, for: format) else {
            completionHandler(SoraError.cameraError(reason: "CameraVideoCapturer.maxFramerate failed: suitable frameRate is not found"))
            return
        }

        capturer.stop { error in
            guard error == nil else {
                completionHandler(SoraError.cameraError(reason: "CameraVideoCapturer.stop failed"))
                return
            }
            flip.start(format: format, frameRate: frameRate) { error in
                guard error == nil else {
                    completionHandler(SoraError.cameraError(reason: "CameraVideoCapturer.start failed"))
                    return
                }
                flip.stream = capturer.stream
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
    public static var handlers = CameraVideoCapturerHandlers()

    /// カメラの位置
    public var position: AVCaptureDevice.Position {
        device.position
    }

    /// 使用中のカメラの位置に対応するデバイス
    /// captureDevice に変更されました
    @available(*, deprecated, renamed: "captureDevice")
    public var currentCameraDevice: AVCaptureDevice? {
        device
    }

    /// 使用中のデバイス
    public var device: AVCaptureDevice

    /// フレームレート
    public private(set) var frameRate: Int?

    /// フォーマット
    public private(set) var format: AVCaptureDevice.Format?

    private var native: RTCCameraVideoCapturer!
    private var nativeDelegate: CameraVideoCapturerDelegate!

    /// 引数に指定した device を利用して CameraVideoCapturer を初期化します。
    /// 自動的に初期化される静的プロパティ、 front/back を定義しています。
    /// 上記以外のデバイスを利用したい場合のみ CameraVideoCapturer を生成してください。
    public init(device: AVCaptureDevice) {
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
                      completionHandler: @escaping ((Error?) -> Void))
    {
        guard isRunning == false else {
            completionHandler(SoraError.cameraError(reason: "isRunning should be false"))
            return
        }

        native.startCapture(with: device,
                            format: format,
                            fps: frameRate)
        { [self] (error: Error?) in
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
            CameraVideoCapturer.handlers.onStart?(self)
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

        native.stopCapture { [self] in
            Logger.debug(type: .cameraVideoCapturer, message: "succeeded to stop \(String(describing: device))")

            // stop が成功した際の処理
            isRunning = false
            CameraVideoCapturer.current = nil
            completionHandler(nil)
            CameraVideoCapturer.handlers.onStop?(self)
        }
    }

    /// 停止前と同じ設定でカメラを再起動します。
    public func restart(completionHandler: @escaping ((Error?) -> Void)) {
        guard let format = format else {
            completionHandler(SoraError.cameraError(reason: "failed to access format"))
            return
        }

        guard let frameRate = frameRate else {
            completionHandler(SoraError.cameraError(reason: "failed to access frame rate"))
            return
        }

        if isRunning {
            stop { [self] (error: Error?) in
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
        } else {
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

    /// カメラを停止後、指定されたパラメーターで起動します。
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

        stop { [self] (error: Error?) in
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

    // MARK: - 廃止された API

    /// シングルトンインスタンス
    /// shared は廃止されました。
    @available(*, unavailable, message: "shared は廃止されました。")
    public static var shared: CameraVideoCapturer?

    /// 利用可能なデバイスのリスト
    /// 名称が devices に変更されました
    @available(*, unavailable, renamed: "devices")
    public static var captureDevices: [AVCaptureDevice] { RTCCameraVideoCapturer.captureDevices() }

    /// 指定したカメラ位置にマッチした最初のデバイスを返します。
    /// 名称が device に変更されました
    @available(*, unavailable, renamed: "device")
    public static func captureDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        nil
    }

    /// `true` であれば接続解除時にカメラを停止します。
    /// 廃止されました。
    @available(*, unavailable, message: "廃止されました")
    public var canStop: Bool = false

    /// :nodoc:
    @available(*, unavailable, message: "suitableFrameRate は廃止されました。 maxFramerate を利用してください。")
    public static func suitableFrameRate(for format: AVCaptureDevice.Format, frameRate: Int) -> Int? {
        nil
    }

    /// カメラの設定
    /// 廃止されました
    @available(*, unavailable, message: "settings は廃止されました。")
    public private(set) var settings: Any?

    /// `true` であれば接続解除時にカメラを停止します。
    @available(*, unavailable, message: "stopWhenDone は廃止されました。")
    public private(set) var stopWhenDone: Bool = false

    /// :nodoc:
    @available(*, unavailable, message: "suitableFormat は廃止されました。 format を利用してください。")
    public static func suitableFormat(for device: AVCaptureDevice, resolution: Any) -> AVCaptureDevice.Format? {
        nil
    }
}

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

    /// カメラの位置
    public var position: AVCaptureDevice.Position

    /// カメラ起動の有無
    public var isEnabled: Bool

    /// 文字列表現を返します。
    public var description: String {
        "\(resolution), \(frameRate)fps"
    }

    /**
     初期化します。

     - parameter resolution: 解像度
     - parameter frameRate: フレームレート
     - parameter position: 配信開始時のカメラの位置
     - parameter isEnabled: カメラの起動の有無
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
        if let editedFrame = CameraVideoCapturer.handlers.onCapture?(cameraVideoCapturer, frame) {
            cameraVideoCapturer.stream?.send(videoFrame: editedFrame)
        } else {
            cameraVideoCapturer.stream?.send(videoFrame: frame)
        }

        VideoCameraInputNode.onCapture(.rtcFrame(nativeFrame))
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

/**
 CameraVideoCapturer のイベントハンドラです。
 */
public class CameraVideoCapturerHandlers {
    /// 生成された映像フレームを受け取ります。
    /// 返した映像フレームがストリームに渡されます。
    public var onCapture: ((CameraVideoCapturer, VideoFrame) -> VideoFrame)?

    /// CameraVideoCapturer.start(format:frameRate:completionHandler) 内で completionHandler の後に実行されます。
    /// そのため、 CameraVideoCapturer.restart(completionHandler) のように、 stop の completionHandler で start を実行する場合、
    /// イベントハンドラは onStart, onStop の順に呼び出されることに注意してください。
    public var onStart: ((CameraVideoCapturer) -> Void)?

    /// CameraVideoCapturer.stop(completionHandler) 内で completionHandler の後に実行されます。
    /// 注意点については、 onStart のコメントを参照してください。
    public var onStop: ((CameraVideoCapturer) -> Void)?

    /// CameraVideoCapturer のイベントハンドラを初期化します。
    public init() {}
}
