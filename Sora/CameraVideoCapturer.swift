import Foundation
import WebRTC

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
    
    public var stream: MediaStream?
    public private(set) var isRunning: Bool = false
    public private(set) var position: CameraPosition = .front
    public var handlers: VideoCapturerHandlers = VideoCapturerHandlers()
    
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
    
    public func stop() {
        if isRunning {
            Logger.debug(type: .cameraVideoCapturer, message: "stop")
            nativeCameraVideoCapturer.stopCapture()
        }
        isRunning = false
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
