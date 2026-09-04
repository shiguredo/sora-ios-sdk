import Foundation
import WebRTC

/// `AVCaptureDevice.Format` をカメラキューへ受け渡すための内部ラッパーです。
///
/// `AVCaptureDevice.Format` 自体は `Sendable` ではありませんが、このラッパーに格納した値は
/// カメラキュー上の `start` に渡す用途に限定します。
struct CameraCaptureFormatBox: @unchecked Sendable {
  let format: AVCaptureDevice.Format
}

/// 公開カメラ API の完了ハンドラーを並行処理境界へ渡すための内部ラッパーです。
private final class CameraOperationCompletionBox: @unchecked Sendable {
  private let completionHandler: (Error?) -> Void

  init(_ completionHandler: @escaping (Error?) -> Void) {
    self.completionHandler = completionHandler
  }

  func callAsFunction(_ error: Error?) {
    completionHandler(error)
  }
}

/// PeerChannel がカメラへ設定した送信ストリームを、`streams` の更新と独立して保持します。
///
/// redirect では一時的に `streams` が空になるため、カメラ停止が完了するまで所有情報を
/// 別途保持しないと、接続失敗時に停止対象を失います。
final class CameraCaptureOwnership: @unchecked Sendable {
  private let lock = NSLock()
  private var senderStream: MediaStream?

  func set(senderStream: MediaStream) {
    lock.lock()
    self.senderStream = senderStream
    lock.unlock()
  }

  func currentSenderStream() -> MediaStream? {
    lock.lock()
    defer { lock.unlock() }
    return senderStream
  }

  func clear(ifOwnedBy senderStream: MediaStream) {
    lock.lock()
    if self.senderStream === senderStream {
      self.senderStream = nil
    }
    lock.unlock()
  }
}

/// 1 つの送信接続でカメラと画面共有を同時に開始しないための予約状態です。
///
/// 実デバイスの非同期開始より前に送信元を予約し、確認と予約の間へ別 API が
/// 割り込む競合を防ぎます。切断後は遅延した開始処理を拒否します。
final class VideoSourceCoordinator: @unchecked Sendable {
  enum ReservationResult: Equatable, Sendable {
    case acquired
    case alreadyReserved
    case unavailable
  }

  private enum Source: Equatable, Sendable {
    case camera
    case screen
  }

  private let lock = NSLock()
  private var source: Source?
  private var revoked = false

  func reserveCamera() -> ReservationResult {
    reserve(.camera)
  }

  func reserveScreen() -> ReservationResult {
    reserve(.screen)
  }

  func releaseCamera() {
    release(.camera)
  }

  func releaseScreen() {
    release(.screen)
  }

  func isReservedForCamera() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return !revoked && source == .camera
  }

  func revoke() {
    lock.lock()
    revoked = true
    lock.unlock()
  }

  private func reserve(_ requestedSource: Source) -> ReservationResult {
    lock.lock()
    defer { lock.unlock() }
    guard !revoked else {
      return .unavailable
    }
    guard let source else {
      self.source = requestedSource
      return .acquired
    }
    return source == requestedSource ? .alreadyReserved : .unavailable
  }

  private func release(_ releasedSource: Source) {
    lock.lock()
    if source == releasedSource {
      source = nil
    }
    lock.unlock()
  }
}

/// SDK と公開 API が行うプロセス全体のカメラ操作を、完了コールバックまで含めて直列化します。
///
/// クリーンアップが失敗した場合はカメラを隔離状態にし、動作状態が不明なまま別接続が
/// start / restart を実行することを防ぎます。停止成功を確認した場合だけ隔離を解除します。
final class CameraVideoCaptureCoordinator: @unchecked Sendable {
  static let shared = CameraVideoCaptureCoordinator()

  private let operationQueue = SerializedAsyncOperationQueue()
  private let lock = NSLock()
  private var quarantined = false
  private var quarantinedCapturer: CameraVideoCapturer?

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
    return !quarantined
  }

  /// クリーンアップ失敗を記録し、以後の start / restart を拒否します。
  /// 実際の停止を再試行できるよう、停止に失敗した capturer を保持します。
  func quarantine(capturer: CameraVideoCapturer? = nil) {
    lock.lock()
    quarantined = true
    if let capturer {
      quarantinedCapturer = capturer
    }
    lock.unlock()
  }

  /// 実際の停止成功を確認した後に隔離状態を解除します。
  func clearQuarantineAfterSuccessfulStop(capturer: CameraVideoCapturer? = nil) {
    lock.lock()
    defer { lock.unlock() }
    if let quarantinedCapturer, quarantinedCapturer !== capturer {
      return
    }
    quarantined = false
    quarantinedCapturer = nil
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
    let coordinator = CameraVideoCaptureCoordinator.shared
    let completionBox = CameraOperationCompletionBox(completionHandler)
    coordinator.enqueue {
      guard coordinator.isAvailable else {
        completionBox(
          SoraError.cameraError(reason: "camera capture is quarantined after a cleanup failure"))
        return
      }
      completionBox(await flipForSDK(capturer))
    }
  }

  /// 共有 coordinator から呼び出す、直列化されていないカメラ切り替え処理です。
  private static func flipUncoordinated(
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

      capturer.stopUncoordinated { error in
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
        flip.startUncoordinated(format: format, frameRate: frameRate) { error in
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
    let coordinator = CameraVideoCaptureCoordinator.shared
    let completionBox = CameraOperationCompletionBox(completionHandler)
    let formatBox = CameraCaptureFormatBox(format: format)
    coordinator.enqueue {
      guard coordinator.isAvailable else {
        completionBox(
          SoraError.cameraError(reason: "camera capture is quarantined after a cleanup failure"))
        return
      }
      guard await CameraVideoCapturer.currentForSDK() == nil else {
        completionBox(SoraError.cameraError(reason: "another camera is already running"))
        return
      }
      completionBox(
        await self.startForSDK(
          format: formatBox.format,
          frameRate: frameRate,
          senderStream: nil))
    }
  }

  /// 共有 coordinator から呼び出す、直列化されていないカメラ開始処理です。
  private func startUncoordinated(
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
    let coordinator = CameraVideoCaptureCoordinator.shared
    let completionBox = CameraOperationCompletionBox(completionHandler)
    coordinator.enqueue {
      guard await CameraVideoCapturer.currentForSDK() === self else {
        if self.isRunning {
          coordinator.quarantine(capturer: self)
        }
        completionBox(SoraError.cameraError(reason: "capturer is not the current camera"))
        return
      }

      let error = await self.stopForSDK()
      if self.isRunning {
        coordinator.quarantine(capturer: self)
      } else {
        coordinator.clearQuarantineAfterSuccessfulStop(capturer: self)
      }
      completionBox(error)
    }
  }

  /// 共有 coordinator から呼び出す、直列化されていないカメラ停止処理です。
  private func stopUncoordinated(completionHandler: @escaping ((Error?) -> Void)) {
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
    let coordinator = CameraVideoCaptureCoordinator.shared
    let completionBox = CameraOperationCompletionBox(completionHandler)
    coordinator.enqueue {
      guard coordinator.isAvailable else {
        completionBox(
          SoraError.cameraError(reason: "camera capture is quarantined after a cleanup failure"))
        return
      }
      let current = await CameraVideoCapturer.currentForSDK()
      guard current == nil || current === self else {
        completionBox(SoraError.cameraError(reason: "another camera is already running"))
        return
      }
      guard !self.isRunning || current === self else {
        coordinator.quarantine(capturer: self)
        completionBox(SoraError.cameraError(reason: "capturer is not the current camera"))
        return
      }
      completionBox(await self.restartForSDK(senderStream: nil))
    }
  }

  /// 共有 coordinator から呼び出す、直列化されていないカメラ再開処理です。
  private func restartUncoordinated(completionHandler: @escaping ((Error?) -> Void)) {
    guard let format else {
      completionHandler(SoraError.cameraError(reason: "failed to access format"))
      return
    }

    guard let frameRate else {
      completionHandler(SoraError.cameraError(reason: "failed to access frame rate"))
      return
    }

    if isRunning {
      stopUncoordinated { [self] (error: Error?) in
        guard error == nil else {
          completionHandler(error)
          return
        }

        startUncoordinated(
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
      startUncoordinated(
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
    let coordinator = CameraVideoCaptureCoordinator.shared
    let completionBox = CameraOperationCompletionBox(completionHandler)
    let formatBox = format.map(CameraCaptureFormatBox.init)
    coordinator.enqueue {
      guard coordinator.isAvailable else {
        completionBox(
          SoraError.cameraError(reason: "camera capture is quarantined after a cleanup failure"))
        return
      }
      guard await CameraVideoCapturer.currentForSDK() === self else {
        completionBox(SoraError.cameraError(reason: "capturer is not the current camera"))
        return
      }
      completionBox(
        await self.changeForSDK(
          format: formatBox?.format,
          frameRate: frameRate))
    }
  }

  /// 共有 coordinator から呼び出す、直列化されていないカメラ設定変更処理です。
  private func changeUncoordinated(
    format: AVCaptureDevice.Format? = nil,
    frameRate: Int? = nil,
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

    stopUncoordinated { [self] (error: Error?) in
      guard error == nil else {
        completionHandler(error)
        return
      }

      startUncoordinated(format: format, frameRate: frameRate) { (error: Error?) in
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
    senderStream: SenderStreamBox?
  ) async -> Error? {
    await withCheckedContinuation { continuation in
      SoraDispatcher.async(on: .camera) {
        // start の完了前からフレームが届く場合があるため、先に送信先を設定する。
        let originalStream = self.stream
        if let senderStream {
          self.stream = senderStream.stream
        }
        self.startUncoordinated(format: format, frameRate: frameRate) { error in
          if error != nil, senderStream != nil {
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
        self.stopUncoordinated { error in
          continuation.resume(returning: error)
        }
      }
    }
  }

  /// SDK のカメラキュー上で再起動し、完了時のエラーを返します。
  func restartForSDK(senderStream: SenderStreamBox?) async -> Error? {
    await withCheckedContinuation { continuation in
      SoraDispatcher.async(on: .camera) {
        let originalStream = self.stream
        if let senderStream {
          self.stream = senderStream.stream
        }
        self.restartUncoordinated { error in
          if error != nil, senderStream != nil {
            self.stream = originalStream
          }
          continuation.resume(returning: error)
        }
      }
    }
  }

  /// SDK のカメラキュー上で設定を変更し、完了時のエラーを返します。
  func changeForSDK(format: AVCaptureDevice.Format?, frameRate: Int?) async -> Error? {
    await withCheckedContinuation { continuation in
      SoraDispatcher.async(on: .camera) {
        self.changeUncoordinated(format: format, frameRate: frameRate) { error in
          continuation.resume(returning: error)
        }
      }
    }
  }

  /// SDK のカメラキュー上でカメラを切り替え、完了時のエラーを返します。
  static func flipForSDK(_ capturer: CameraVideoCapturer) async -> Error? {
    await withCheckedContinuation { continuation in
      CameraVideoCapturer.flipUncoordinated(capturer) { error in
        continuation.resume(returning: error)
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
