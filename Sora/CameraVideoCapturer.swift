import Foundation
import WebRTC

/// `AVCaptureDevice.Format` をカメラキューへ受け渡すための内部ラッパーです。
///
/// `AVCaptureDevice.Format` 自体は `Sendable` ではありませんが、このラッパーに格納した値は
/// カメラキュー上の `start` に渡す用途に限定します。
struct CameraCaptureFormatBox: @unchecked Sendable {
  let format: AVCaptureDevice.Format
}

/// SDK が行う process-wide のカメラ操作を、完了コールバックまで含めて直列化します。
///
/// cleanup が失敗した場合はカメラを隔離状態にし、動作状態が不明なまま別接続が
/// start / restart を実行することを防ぎます。停止成功を確認した場合だけ隔離を解除します。
final class CameraVideoCaptureCoordinator: @unchecked Sendable {
  static let shared = CameraVideoCaptureCoordinator()

  private let operationQueue = SerializedAsyncOperationQueue()
  private let lock = NSLock()
  private var quarantinedLease: VideoHardMuteLease?

  /// カメラ操作を process-wide のキューへ投入します。
  @discardableResult
  func enqueue(_ operation: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
    operationQueue.enqueue(operation)
  }

  /// カメラ操作を process-wide のキューで実行し、結果を返します。
  func perform<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T {
    await operationQueue.perform(operation)
  }

  /// カメラ操作を process-wide のキューで実行し、結果を返します。
  func perform<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T
  {
    try await operationQueue.perform(operation)
  }

  /// 新しい start / restart を実行できる状態かを返します。
  var isAvailable: Bool {
    lock.lock()
    defer { lock.unlock() }
    return quarantinedLease == nil
  }

  /// cleanup 失敗を記録し、以後の start / restart を拒否します。
  func quarantine(lease: VideoHardMuteLease) {
    lock.lock()
    quarantinedLease = lease
    lock.unlock()
  }

  /// 実際の停止成功を確認した後に隔離状態を解除します。
  func clearQuarantineAfterSuccessfulStop() {
    lock.lock()
    quarantinedLease = nil
    lock.unlock()
  }

  /// 隔離状態をテストから確認します。
  var isQuarantined: Bool {
    !isAvailable
  }

  /// current capturer の送信先が、切断対象の送信ストリームと一致するかを返します。
  static func isOwned(currentStream: MediaStream?, by senderStream: MediaStream) -> Bool {
    currentStream === senderStream
  }
}

// カメラの共有状態は既存のカメラ用キューで扱う前提のため、 @unchecked Sendable を付与します。
/// 解像度やフレームレートなどの設定は `start` 実行時に指定します。
/// カメラはパブリッシャーまたはグループの接続時に自動的に起動 (起動済みなら再起動) されます。
///
/// カメラの設定を変更したい場合は、 `change` を実行します。
public final class CameraVideoCapturer: @unchecked Sendable {
  // MARK: インスタンスの取得

  /// 利用可能なデバイスのリスト
  /// RTCCameraVideoCapturer.captureDevices を返します。
  public static var devices: [AVCaptureDevice] { RTCCameraVideoCapturer.captureDevices() }

  /// 前面のカメラに対応するデバイス
  public static let front: CameraVideoCapturer? = {
    if let device = device(for: .front) {
      return CameraVideoCapturer(device: device)
    } else {
      return nil
    }
  }()

  /// 背面のカメラに対応するデバイス
  public static let back: CameraVideoCapturer? = {
    if let device = device(for: .back) {
      return CameraVideoCapturer(device: device)
    } else {
      return nil
    }
  }()

  // TODO(zztkm): 共有状態を actor に移し、 async API に置き換えて concurrency-safe にする。
  /// 起動中のデバイス
  public private(set) nonisolated(unsafe) static var current: CameraVideoCapturer?

  // flip 実行中のフラグ。camera queue 上で切り替え中を表現し、
  // 連続実行の re-entrance を防ぐ。camera queue 上でのみ読み書きする。
  nonisolated(unsafe) private static var isFlipping = false

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
  public static func format(
    width: Int32, height: Int32, for device: AVCaptureDevice, frameRate: Int? = nil
  ) -> AVCaptureDevice.Format? {
    func calcDiff(_ targetWidth: Int32, _ targetHeight: Int32, _ format: AVCaptureDevice.Format)
      -> Int32
    {
      let dimension = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      return abs(targetWidth - dimension.width) + abs(targetHeight - dimension.height)
    }

    let supportedFormats = RTCCameraVideoCapturer.supportedFormats(for: device)

    // 指定された解像度に近いフォーマットを絞り込む
    guard let diff = supportedFormats.map({ calcDiff(width, height, $0) }).min() else {
      return nil
    }
    let formats = supportedFormats.filter { calcDiff(width, height, $0) == diff }
    guard !formats.isEmpty else {
      return nil
    }

    // この関数の引数に frameRate が指定された場合、フレームレートも考慮する
    guard let frameRate else {
      return formats.first
    }
    return formats.filter {
      $0.videoSupportedFrameRateRanges.contains(where: {
        Int($0.minFrameRate) <= frameRate && frameRate <= Int($0.maxFrameRate)
      })
    }.first ?? formats.first
  }

  /// 指定された FPS 値をサポートしているレンジが存在すれば、その値を返します。
  /// 存在しない場合はサポートされているレンジの中で最大の値を返します。
  public static func maxFrameRate(_ frameRate: Int, for format: AVCaptureDevice.Format) -> Int? {
    if format.videoSupportedFrameRateRanges.contains(where: {
      Int($0.minFrameRate) <= frameRate && frameRate <= Int($0.maxFrameRate)
    }) {
      return frameRate
    }
    return format.videoSupportedFrameRateRanges
      .max { $0.maxFrameRate < $1.maxFrameRate }
      .map { Int($0.maxFrameRate) }
  }

  /// 引数に指定された capturer を停止し、反対の position を持つ CameraVideoCapturer を起動します。
  /// CameraVideoCapturer の起動には、 capturer と近い設定のフォーマットとフレームレートが利用されます。
  /// また、起動された CameraVideoCapturer には capturer の保持する MediaStream が設定されます。
  ///
  /// 切り替え先の stream は start より前に設定します。RTCCameraVideoCapturer は start の
  /// completion より前から frame callback を発生させることがあり、静的に再利用される
  /// front / back capturer に前回利用時の stream が残っていると、旧 stream へ frame が
  /// 送信されるためです。stream を先行設定し、start 失敗時は元の stream へ rollback します。
  /// 連続実行時の競合は camera queue 上の re-entrance フラグで防ぎます。
  /// 引数には CameraVideoCapturer.current を渡してください。
  public static func flip(
    _ capturer: CameraVideoCapturer, completionHandler: @escaping ((Error?) -> Void)
  ) {
    // camera queue (libwebrtc の capture session queue) で直列化する。
    // 連続した flip (フリップボタンの連続タップ等) が同時に実行され、
    // stop / start の callback が入れ替わる競合を防ぐ。
    SoraDispatcher.async(on: .camera) {
      // 引数が現在の capturer と一致することを確認する。
      // (別の capturer を渡すと、停止していない capturer への stop / stream 代入が起こるため)
      guard capturer === CameraVideoCapturer.current else {
        completionHandler(
          SoraError.cameraError(reason: "capturer is not the current camera"))
        return
      }

      // 既に flip が実行中の場合はエラーを返す (re-entrance 防止)。
      // camera queue 上で直列化されるが、stop / start の completion は
      // 後続の queue hop として実行されるため、フラグで切り替え中を表現する。
      guard !CameraVideoCapturer.isFlipping else {
        completionHandler(
          SoraError.cameraError(reason: "camera flip is already in progress"))
        return
      }
      CameraVideoCapturer.isFlipping = true

      // フラグは同期ブロックで解除せず、stop / start の完了まで維持する。
      // (非同期部分の間に 2 回目の flip が呼ばれてもエラーになるようにする)

      guard let format = capturer.format else {
        CameraVideoCapturer.isFlipping = false
        completionHandler(SoraError.cameraError(reason: "format should not be nil"))
        return
      }

      guard let capturerFrameRate = capturer.frameRate else {
        CameraVideoCapturer.isFlipping = false
        completionHandler(SoraError.cameraError(reason: "frameRate should not be nil"))
        return
      }

      // 反対の position を持つ CameraVideoCapturer を取得します。
      guard let flip: CameraVideoCapturer = (capturer.device.position == .front ? .back : .front)
      else {
        let name = capturer.device.position == .front ? "back" : "front"
        CameraVideoCapturer.isFlipping = false
        completionHandler(SoraError.cameraError(reason: "\(name) camera is not found"))
        return
      }

      let dimension = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      guard
        let format = CameraVideoCapturer.format(
          width: dimension.width,
          height: dimension.height,
          for: flip.device,
          frameRate: capturerFrameRate)
      else {
        CameraVideoCapturer.isFlipping = false
        completionHandler(
          SoraError.cameraError(
            reason: "CameraVideoCapturer.format failed: suitable format is not found"))
        return
      }

      guard let frameRate = CameraVideoCapturer.maxFrameRate(capturerFrameRate, for: format)
      else {
        CameraVideoCapturer.isFlipping = false
        completionHandler(
          SoraError.cameraError(
            reason:
              "CameraVideoCapturer.maxFramerate failed: suitable frameRate is not found"))
        return
      }

      // 切り替え先の stream を start より前に設定する。
      // (元の capturer が保持する stream を引き継ぐ)
      // start 失敗時はもとの状態 (nil または元の stream) へ rollback する。
      let originalStream = flip.stream
      flip.stream = capturer.stream

      Logger.debug(
        type: .cameraVideoCapturer,
        message: "starting flip to \(flip.device)")

      capturer.stop { error in
        guard error == nil else {
          // stop に失敗した場合は切り替え先の stream を rollback する
          flip.stream = originalStream
          CameraVideoCapturer.isFlipping = false
          Logger.error(
            type: .cameraVideoCapturer,
            message: "failed to stop capturer: \(String(describing: error))")
          completionHandler(SoraError.cameraError(reason: "CameraVideoCapturer.stop failed"))
          return
        }
        flip.start(format: format, frameRate: frameRate) { error in
          guard error == nil else {
            // start に失敗した場合は切り替え先の stream を rollback する
            flip.stream = originalStream
            CameraVideoCapturer.isFlipping = false
            Logger.error(
              type: .cameraVideoCapturer,
              message: "failed to start flip capturer: \(String(describing: error))")
            completionHandler(
              SoraError.cameraError(reason: "CameraVideoCapturer.start failed"))
            return
          }
          CameraVideoCapturer.isFlipping = false
          Logger.debug(
            type: .cameraVideoCapturer,
            message: "succeeded to flip to \(flip.device)")
          completionHandler(nil)
        }
      }
    }
  }

  // MARK: プロパティ

  /// 出力先のストリーム
  public var stream: MediaStream?

  /// カメラが起動中であれば ``true``
  public private(set) var isRunning: Bool = false

  // TODO(zztkm): イベントハンドラを actor 経由で管理し、 @Sendable な API に置き換える。
  /// イベントハンドラ
  public nonisolated(unsafe) static var handlers = CameraVideoCapturerHandlers()

  /// カメラの位置
  public var position: AVCaptureDevice.Position {
    device.position
  }

  /// 使用中のデバイス
  public var device: AVCaptureDevice

  /// フレームレート
  public private(set) var frameRate: Int?

  /// フォーマット
  public private(set) var format: AVCaptureDevice.Format?

  // init で必ず初期化されるため安全
  // swiftlint:disable:next implicitly_unwrapped_optional
  private var native: RTCCameraVideoCapturer!
  // init で必ず初期化されるため安全
  // swiftlint:disable:next implicitly_unwrapped_optional
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

  /// カメラを起動します。
  ///
  /// このメソッドを実行すると、 `UIDevice` の
  /// `beginGeneratingDeviceOrientationNotifications()` が実行されます。
  /// `beginGeneratingDeviceOrientationNotifications()` または
  /// `endGeneratingDeviceOrientationNotifications()` を使う際は
  /// 必ず対に実行するように注意してください。
  public func start(
    format: AVCaptureDevice.Format,
    frameRate: Int,
    completionHandler: @escaping ((Error?) -> Void)
  ) {
    guard isRunning == false else {
      completionHandler(SoraError.cameraError(reason: "isRunning should be false"))
      return
    }

    native.startCapture(
      with: device,
      format: format,
      fps: frameRate
    ) { [self] (error: Error?) in
      guard error == nil else {
        completionHandler(error)
        return
      }
      Logger.debug(
        type: .cameraVideoCapturer,
        message: "succeeded to start \(device) with \(format), \(frameRate)fps")

      // start が成功した際の処理
      self.format = format
      self.frameRate = frameRate
      isRunning = true
      CameraVideoCapturer.current = self
      completionHandler(nil)
      CameraVideoCapturer.handlers.onStart?(self)
    }
  }

  /// カメラを停止します。
  ///
  /// このメソッドを実行すると、 `UIDevice` の
  /// `endGeneratingDeviceOrientationNotifications()` が実行されます。
  /// `beginGeneratingDeviceOrientationNotifications()` または
  /// `endGeneratingDeviceOrientationNotifications()` を使う際は
  /// 必ず対に実行するように注意してください。
  public func stop(completionHandler: @escaping ((Error?) -> Void)) {
    guard isRunning else {
      completionHandler(SoraError.cameraError(reason: "isRunning should be true"))
      return
    }

    native.stopCapture { [self] in
      Logger.debug(
        type: .cameraVideoCapturer,
        message: "succeeded to stop \(String(describing: device))")

      // stop が成功した際の処理
      isRunning = false
      CameraVideoCapturer.current = nil
      completionHandler(nil)
      CameraVideoCapturer.handlers.onStop?(self)
    }
  }

  /// 停止前と同じ設定でカメラを再起動します。
  public func restart(completionHandler: @escaping ((Error?) -> Void)) {
    guard let format else {
      completionHandler(SoraError.cameraError(reason: "failed to access format"))
      return
    }

    guard let frameRate else {
      completionHandler(SoraError.cameraError(reason: "failed to access frame rate"))
      return
    }

    if isRunning {
      stop { [self] (error: Error?) in
        guard error == nil else {
          completionHandler(error)
          return
        }

        start(
          format: format,
          frameRate: frameRate
        ) { (error: Error?) in
          guard error == nil else {
            completionHandler(error)
            return
          }

          Logger.debug(type: .cameraVideoCapturer, message: "succeeded to restart")
          completionHandler(nil)
        }
      }
    } else {
      start(
        format: format,
        frameRate: frameRate
      ) { (error: Error?) in
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
  public func change(
    format: AVCaptureDevice.Format? = nil, frameRate: Int? = nil,
    completionHandler: @escaping ((Error?) -> Void)
  ) {
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

}

extension CameraVideoCapturer {
  /// SDK のカメラキュー上で現在の capturer を取得します。
  static func currentForSDK() async -> CameraVideoCapturer? {
    await withCheckedContinuation { continuation in
      SoraDispatcher.async(on: .camera) {
        continuation.resume(returning: CameraVideoCapturer.current)
      }
    }
  }

  /// SDK のカメラキュー上で起動し、完了時のエラーを返します。
  func startForSDK(
    format: AVCaptureDevice.Format,
    frameRate: Int,
    senderStream: SenderStreamBox
  ) async -> Error? {
    await withCheckedContinuation { continuation in
      SoraDispatcher.async(on: .camera) {
        // start の完了前からフレームが届く場合があるため、先に送信先を設定する。
        let originalStream = self.stream
        self.stream = senderStream.stream
        self.start(format: format, frameRate: frameRate) { error in
          if error != nil {
            self.stream = originalStream
          }
          continuation.resume(returning: error)
        }
      }
    }
  }

  /// SDK のカメラキュー上で停止し、完了時のエラーを返します。
  func stopForSDK() async -> Error? {
    await withCheckedContinuation { continuation in
      SoraDispatcher.async(on: .camera) {
        self.stop { error in
          continuation.resume(returning: error)
        }
      }
    }
  }

  /// SDK のカメラキュー上で再起動し、完了時のエラーを返します。
  func restartForSDK(senderStream: SenderStreamBox) async -> Error? {
    await withCheckedContinuation { continuation in
      SoraDispatcher.async(on: .camera) {
        let originalStream = self.stream
        self.stream = senderStream.stream
        self.restart { error in
          if error != nil {
            self.stream = originalStream
          }
          continuation.resume(returning: error)
        }
      }
    }
  }
}

/// `CameraVideoCapturer` の設定を表すオブジェクトです。
public struct CameraSettings: CustomStringConvertible {
  /// デフォルトの設定。
  public static var `default`: CameraSettings { CameraSettings() }

  /// `CameraVideoCapturer` で使用する映像解像度を表すenumです。
  public enum Resolution: Sendable {
    /// QVGA, 320x240
    case qvga240p

    /// VGA, 640x480
    case vga480p

    /// qHD540p, 960x540
    case qhd540p

    /// HD 720p, 1280x720
    case hd720p

    /// HD 1080p, 1920x1080
    case hd1080p

    /// UHD 2160p, 3840x2160
    case uhd2160p

    /// UHD 3024p, 4032x3024
    case uhd3024p

    /// 横方向のピクセル数を返します。
    public var width: Int32 {
      switch self {
      case .qvga240p: return 320
      case .vga480p: return 640
      case .qhd540p: return 960
      case .hd720p: return 1280
      case .hd1080p: return 1920
      case .uhd2160p: return 3840
      case .uhd3024p: return 4032
      }
    }

    /// 縦方向のピクセル数を返します。
    public var height: Int32 {
      switch self {
      case .qvga240p: return 240
      case .vga480p: return 480
      case .qhd540p: return 540
      case .hd720p: return 720
      case .hd1080p: return 1080
      case .uhd2160p: return 2160
      case .uhd3024p: return 3024
      }
    }
  }

  /// 希望する映像解像度。
  ///
  /// 可能な限りここで指定された値が尊重されますが、
  /// 例えばデバイス側が対応していない値が指定された場合などは、
  /// ここで指定された値と異なる値が実際には使用されることがあります。
  public var resolution: Resolution

  /// 希望する映像フレームレート(Frames Per Second)。
  ///
  /// 可能な限りここで指定された値が尊重されますが、
  /// 例えばデバイス側が対応していない値が指定された場合などは、
  /// ここで指定された値と異なる値が実際には使用されることがあります。
  public var frameRate: Int

  /// カメラの位置
  public var position: AVCaptureDevice.Position

  /// カメラ起動の有無
  public var isEnabled: Bool

  /// 文字列表現を返します。
  public var description: String {
    "\(resolution), \(frameRate)fps"
  }

  /// 初期化します。
  ///
  /// - parameter resolution: 解像度
  /// - parameter frameRate: フレームレート
  /// - parameter position: 配信開始時のカメラの位置
  /// - parameter isEnabled: カメラの起動の有無
  public init(
    resolution: Resolution = .hd720p, frameRate: Int = 30,
    position: AVCaptureDevice.Position = .front, isEnabled: Bool = true
  ) {
    self.resolution = resolution
    self.frameRate = frameRate
    self.position = position
    self.isEnabled = isEnabled
  }
}

// MARK: -

private class CameraVideoCapturerDelegate: NSObject, RTCVideoCapturerDelegate {
  weak var cameraVideoCapturer: CameraVideoCapturer?

  init(cameraVideoCapturer: CameraVideoCapturer) {
    self.cameraVideoCapturer = cameraVideoCapturer
  }

  func capturer(_ capturer: RTCVideoCapturer, didCapture nativeFrame: RTCVideoFrame) {
    guard let cameraVideoCapturer else {
      Logger.debug(type: .cameraVideoCapturer, message: "cameraVideoCapturer is nil")
      return
    }
    let frame = VideoFrame.native(capturer: capturer, frame: nativeFrame)
    if let editedFrame = CameraVideoCapturer.handlers.onCapture?(cameraVideoCapturer, frame) {
      cameraVideoCapturer.stream?.send(videoFrame: editedFrame)
    } else {
      cameraVideoCapturer.stream?.send(videoFrame: frame)
    }
  }
}

// MARK: -

private let resolutionTable: PairTable<String, CameraSettings.Resolution> =
  PairTable(
    name: "CameraVideoCapturer.Settings.Resolution",
    pairs: [
      ("qvga240p", .qvga240p),
      ("vga480p", .vga480p),
      ("hd720p", .hd720p),
      ("hd1080p", .hd1080p),
    ])

/// :nodoc:
extension CameraSettings.Resolution: Codable {
  public init(from decoder: Decoder) throws {
    self = try resolutionTable.decode(from: decoder)
  }

  public func encode(to encoder: Encoder) throws {
    try resolutionTable.encode(self, to: encoder)
  }
}

/// CameraVideoCapturer のイベントハンドラです。
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
