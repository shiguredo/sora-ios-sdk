import Foundation
import WebRTC

public class CameraVideoCapturer: VideoCapturer {
    
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
    public static func suitableFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        // TODO
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        return formats[0]
    }
    
    /// :nodoc:
    public static func suitableFrameRate(for format: AVCaptureDevice.Format) -> Int? {
        return format.videoSupportedFrameRateRanges.max { a, b in
            return a.maxFrameRate < b.maxFrameRate
            }.map { return Int($0.maxFrameRate) }
    }
    
    // MARK: プロパティ
    
    /// 出力先のストリーム
    public var stream: MediaStream?
    
    /// カメラが起動中であれば ``true``
    public private(set) var isRunning: Bool = false
    
    /// イベントハンドラ
    public var handlers: VideoCapturerHandlers = VideoCapturerHandlers()
    
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
    
    /// カメラを起動します。
    public func start() {
        if isRunning {
            return
        }
        
        Logger.debug(type: .cameraVideoCapturer, message: "try start all devices")
        for device in RTCCameraVideoCapturer.captureDevices() {
            Logger.debug(type: .cameraVideoCapturer, message: "try start \(device)")
            guard let format = CameraVideoCapturer.suitableFormat(for: device) else {
                Logger.debug(type: .cameraVideoCapturer,
                             message: "    suitable format is not found")
                break
            }
            guard let fps = CameraVideoCapturer.suitableFrameRate(for: format) else {
                Logger.debug(type: .cameraVideoCapturer,
                             message: "    suitable frame rate is not found")
                break
            }

            nativeCameraVideoCapturer.startCapture(with: device, format: format, fps: fps)
            Logger.debug(type: .cameraVideoCapturer, message: "did start \(device)")
        }
        Logger.debug(type: .cameraVideoCapturer, message: "did start all devices")

        isRunning = true
    }
    
    /// カメラを停止します。
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

private class CameraVideoCapturerDelegate: NSObject, RTCVideoCapturerDelegate {
    
    weak var cameraVideoCapturer: CameraVideoCapturer!
    
    init(cameraVideoCapturer: CameraVideoCapturer) {
        self.cameraVideoCapturer = cameraVideoCapturer
    }
    
    func capturer(_ capturer: RTCVideoCapturer, didCapture nativeFrame: RTCVideoFrame) {
        let frame = VideoFrame.native(capturer: capturer, frame: nativeFrame)
        cameraVideoCapturer.stream?.render(videoFrame: frame)
        cameraVideoCapturer.handlers.onCaptureHandler?(frame)
    }
    
}
