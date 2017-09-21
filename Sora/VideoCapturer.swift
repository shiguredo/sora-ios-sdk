import Foundation
import WebRTC

public class VideoCapturerHandlers {
    
    public var onCaptureHandler: ((VideoFrame) -> Void)?
    
}

public protocol VideoCapturer {
    
    var nativeCapturer: RTCVideoCapturer? { get }
    var handlers: VideoCapturerHandlers { get }
    
    func start()
    func stop()
    
}

public protocol VideoFilter {
    
    func filterFrame(_ frame: VideoFrame) -> VideoFrame
    
}

public class CameraVideoCapturer: VideoCapturer {

    public static var shared: CameraVideoCapturer = CameraVideoCapturer()

    public static var captureDevices: [AVCaptureDevice] {
        get { return RTCCameraVideoCapturer.captureDevices() }
    }
    
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
    
    public static func suitableFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        // TODO
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        return formats[0]
    }
    
    public static func suitableFrameRate(for format: AVCaptureDevice.Format) -> Int? {
        return format.videoSupportedFrameRateRanges.max { a, b in
            return a.maxFrameRate < b.maxFrameRate
            }.map { return Int($0.maxFrameRate) }
    }
    
    public var nativeCapturer: RTCVideoCapturer? {
        get { return nativeCameraVideoCapturer }
    }
    
    private var _isRunning: Bool = false
    public var isRunning: Bool { get { return _isRunning } }
    
    private var _position: CameraPosition = .front
    
    public var position: CameraPosition {
        get { return _position }
        
        set {
            if _isRunning {
                stopCurrentCameraDevice()
                _position = newValue
                startCurrentCameraDevice()
            } else {
                _position = newValue
            }
        }
    }
    
    public var handlers: VideoCapturerHandlers = VideoCapturerHandlers()

    private var nativeCameraVideoCapturer: RTCCameraVideoCapturer!
    private var frontCameraDevice: AVCaptureDevice?
    private var backCameraDevice: AVCaptureDevice?
    private var nativeDelegate: CameraVideoCapturerDelegate!
    
    private var currentCameraDevice: AVCaptureDevice? {
        get {
            switch position {
            case .front:
                return frontCameraDevice
            case .back:
                return backCameraDevice
            }
        }
    }
    
    init() {
        nativeDelegate = CameraVideoCapturerDelegate(cameraVideoCapturer: self)
        nativeCameraVideoCapturer = RTCCameraVideoCapturer(delegate: nativeDelegate)
        frontCameraDevice = CameraVideoCapturer.captureDevice(for: .front)
        backCameraDevice = CameraVideoCapturer.captureDevice(for: .back)
    }
    
    func startCurrentCameraDevice() {
        guard let device = currentCameraDevice else { return }
        guard let format = CameraVideoCapturer.suitableFormat(for: device) else { return }
        guard let fps = CameraVideoCapturer.suitableFrameRate(for: format) else { return }
        nativeCameraVideoCapturer.startCapture(with: device, format: format, fps: fps)
    }
    
    func stopCurrentCameraDevice() {
        nativeCameraVideoCapturer.stopCapture()
    }
    
    public func start() {
        if _isRunning {
            return
        }
        Log.debug(type: .sora, message: "start camera video capture")
        startCurrentCameraDevice()
        _isRunning = true
    }
    
    public func stop() {
        if _isRunning {
            Log.debug(type: .sora, message: "stop camera video capture")
            stopCurrentCameraDevice()
        }
        _isRunning = false
    }
    
}

private class CameraVideoCapturerDelegate: NSObject, RTCVideoCapturerDelegate {
    
    weak var cameraVideoCapturer: CameraVideoCapturer!
    
    init(cameraVideoCapturer: CameraVideoCapturer) {
        self.cameraVideoCapturer = cameraVideoCapturer
    }
    
    func capturer(_ capturer: RTCVideoCapturer, didCapture frame: RTCVideoFrame) {
        let frame = VideoFrame.native(capturer: capturer, frame: frame)
        cameraVideoCapturer.handlers.onCaptureHandler?(frame)
    }
    
}
