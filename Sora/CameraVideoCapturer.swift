import Foundation
import WebRTC

/// `AVCaptureDevice.Format` をカメラキューへ受け渡すための内部ラッパーです。
///
/// `AVCaptureDevice.Format` 自体は `Sendable` ではありませんが、このラッパーに格納した値は
/// カメラキュー上の `start` に渡す用途に限定します。`@unchecked Sendable` はこの前提に
/// 依存します。
struct CameraCaptureFormatBox: @unchecked Sendable {
  let format: AVCaptureDevice.Format
}

/// 公開カメラ API の完了ハンドラーを並行処理境界へ渡すための内部ラッパーです。
///
/// `@unchecked Sendable` としているのは、保持する closure が init で確定した `let` で、
/// この box をカメラ操作用の直列 queue へ渡す用途に限定しているためです。
final class CameraOperationCompletionBox: @unchecked Sendable {
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
///
/// `@unchecked Sendable` としているのは、可変状態が `senderStream` だけで、
/// その読み書きをすべて `lock` で排他しているためです。
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

/// 映像送信元の開始予約を、接続と送信ストリームに紐付けて管理します。
///
/// 状態は process-wide のレジストリへ集約し、SDK 内部 API と公開カメラ API が
/// 同じ送信ストリームへカメラと画面共有を同時に開始する競合を防ぎます。
/// 非同期開始は世代付きの予約で検証し、停止または切断後に遅れて完了した開始を無効化します。
///
/// `@unchecked Sendable` としているのは、可変状態が process-wide な `Registry` だけで、
/// その読み書きを `Registry` の lock で排他しているためです。この型自身が持つのは
/// init で確定する `ownerID` だけです。
final class VideoSourceCoordinator: @unchecked Sendable {
  enum Source: Equatable, Sendable {
    case camera
    case screen
  }

  struct Reservation: Equatable, Sendable {
    fileprivate let ownerID: UUID
    fileprivate let generation: UInt64
    fileprivate let source: Source
  }

  private enum State: Equatable, Sendable {
    case cameraStarting
    case camera
    case screenStarting
    case screen
    case screenStopping
    case screenCleanupFailed

    var source: Source {
      switch self {
      case .cameraStarting, .camera:
        return .camera
      case .screenStarting, .screen, .screenStopping, .screenCleanupFailed:
        return .screen
      }
    }
  }

  /// `MediaStream` を弱参照で包む内部ラッパーです。
  ///
  /// `@unchecked Sendable` としているのは、`value` の読み書きが外側の `Registry` の
  /// lock 下でのみ行われるためです。
  private final class WeakStream: @unchecked Sendable {
    weak var value: MediaStream?

    init(_ value: MediaStream) {
      self.value = value
    }
  }

  private struct Entry {
    var generation: UInt64 = 0
    var state: State?
    var stream: WeakStream?
    var revoked = false
  }

  /// 送信元の予約状態を接続ごとに保持する process-wide なレジストリです。
  ///
  /// `@unchecked Sendable` としているのは、可変状態が `entries` だけで、
  /// その読み書きをすべて `lock` で排他しているためです。
  private final class Registry: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    func register(ownerID: UUID) {
      withLock {
        entries[ownerID] = Entry()
      }
    }

    func unregister(ownerID: UUID) {
      _ = withLock {
        entries.removeValue(forKey: ownerID)
      }
    }

    func beginCamera(ownerID: UUID, stream: MediaStream) -> Reservation? {
      withLock {
        guard var entry = entries[ownerID], !entry.revoked else {
          return nil
        }
        guard entry.state == nil || entry.state == .camera else {
          return nil
        }
        guard !hasScreenReservationLocked(for: stream) else {
          return nil
        }
        entry.generation &+= 1
        entry.state = .cameraStarting
        entry.stream = WeakStream(stream)
        entries[ownerID] = entry
        return Reservation(
          ownerID: ownerID,
          generation: entry.generation,
          source: .camera)
      }
    }

    func beginScreen(ownerID: UUID, stream: MediaStream) -> Reservation? {
      withLock {
        guard var entry = entries[ownerID], !entry.revoked, entry.state == nil else {
          return nil
        }
        guard !hasCameraReservationLocked(for: stream) else {
          return nil
        }
        entry.generation &+= 1
        entry.state = .screenStarting
        entry.stream = WeakStream(stream)
        entries[ownerID] = entry
        return Reservation(
          ownerID: ownerID,
          generation: entry.generation,
          source: .screen)
      }
    }

    func completeCamera(_ reservation: Reservation, active: Bool) -> Bool {
      withLock {
        guard reservation.source == .camera,
          var entry = validEntryLocked(for: reservation),
          entry.state == .cameraStarting
        else {
          return false
        }
        entry.state = active ? .camera : nil
        if !active {
          entry.stream = nil
        }
        entries[reservation.ownerID] = entry
        return active
      }
    }

    func cancelCamera(_ reservation: Reservation) {
      withLock {
        guard reservation.source == .camera,
          var entry = entries[reservation.ownerID],
          entry.generation == reservation.generation,
          entry.state?.source == .camera
        else {
          return
        }
        entry.generation &+= 1
        entry.state = nil
        entry.stream = nil
        entries[reservation.ownerID] = entry
      }
    }

    func completeScreenStart(_ reservation: Reservation) -> Bool {
      withLock {
        guard reservation.source == .screen,
          var entry = validEntryLocked(for: reservation),
          entry.state == .screenStarting
        else {
          return false
        }
        entry.state = .screen
        entries[reservation.ownerID] = entry
        return true
      }
    }

    func failScreenStart(_ reservation: Reservation) {
      withLock {
        guard reservation.source == .screen,
          var entry = validEntryLocked(for: reservation),
          entry.state == .screenStarting
        else {
          return
        }
        entry.state = nil
        entry.stream = nil
        entries[reservation.ownerID] = entry
      }
    }

    func isValid(_ reservation: Reservation) -> Bool {
      withLock {
        validEntryLocked(for: reservation)?.state?.source == reservation.source
      }
    }

    func beginScreenStop(
      ownerID: UUID,
      startReservation: Reservation? = nil
    ) -> Reservation? {
      withLock {
        guard var entry = entries[ownerID], entry.state?.source == .screen else {
          return nil
        }
        if let startReservation {
          guard startReservation.ownerID == ownerID,
            startReservation.source == .screen,
            startReservation.generation == entry.generation,
            entry.state == .screenStarting || entry.state == .screen
          else {
            return nil
          }
        }
        if entry.state == .screenStopping {
          return Reservation(
            ownerID: ownerID,
            generation: entry.generation,
            source: .screen)
        }
        entry.generation &+= 1
        entry.state = .screenStopping
        entries[ownerID] = entry
        return Reservation(
          ownerID: ownerID,
          generation: entry.generation,
          source: .screen)
      }
    }

    func finishScreenStop(_ reservation: Reservation, stopped: Bool) {
      withLock {
        guard reservation.source == .screen,
          var entry = entries[reservation.ownerID],
          entry.generation == reservation.generation,
          entry.state == .screenStopping
        else {
          return
        }
        entry.state = stopped ? nil : .screenCleanupFailed
        if stopped {
          entry.stream = nil
        }
        entries[reservation.ownerID] = entry
      }
    }

    func releaseCamera(ownerID: UUID) {
      withLock {
        guard var entry = entries[ownerID], entry.state?.source == .camera else {
          return
        }
        entry.generation &+= 1
        entry.state = nil
        entry.stream = nil
        entries[ownerID] = entry
      }
    }

    func revoke(ownerID: UUID) {
      withLock {
        guard var entry = entries[ownerID] else {
          return
        }
        entry.revoked = true
        entry.generation &+= 1
        if entry.state?.source == .camera {
          entry.state = nil
          entry.stream = nil
        } else if entry.state?.source == .screen {
          entry.state = .screenStopping
        }
        entries[ownerID] = entry
      }
    }

    func hasScreenReservation(for stream: MediaStream?) -> Bool {
      guard let stream else {
        return false
      }
      return withLock {
        hasScreenReservationLocked(for: stream)
      }
    }

    func releaseCameraReservations(for stream: MediaStream, excluding ownerID: UUID? = nil) {
      withLock {
        for (candidateOwnerID, var entry) in entries
        where candidateOwnerID != ownerID
          && entry.state == .camera
          && entry.stream?.value === stream
        {
          entry.generation &+= 1
          entry.state = nil
          entry.stream = nil
          entries[candidateOwnerID] = entry
        }
      }
    }

    private func validEntryLocked(for reservation: Reservation) -> Entry? {
      guard let entry = entries[reservation.ownerID],
        !entry.revoked,
        entry.generation == reservation.generation
      else {
        return nil
      }
      return entry
    }

    private func hasScreenReservationLocked(for stream: MediaStream) -> Bool {
      entries.values.contains {
        $0.state?.source == .screen && $0.stream?.value === stream
      }
    }

    private func hasCameraReservationLocked(for stream: MediaStream) -> Bool {
      entries.values.contains {
        !$0.revoked && $0.state?.source == .camera && $0.stream?.value === stream
      }
    }

    private func withLock<T>(_ operation: () -> T) -> T {
      lock.lock()
      defer { lock.unlock() }
      return operation()
    }
  }

  private static let registry = Registry()
  private let ownerID = UUID()

  init() {
    Self.registry.register(ownerID: ownerID)
  }

  deinit {
    Self.registry.unregister(ownerID: ownerID)
  }

  func beginCamera(stream: MediaStream) -> Reservation? {
    Self.registry.beginCamera(ownerID: ownerID, stream: stream)
  }

  func beginScreen(stream: MediaStream) -> Reservation? {
    Self.registry.beginScreen(ownerID: ownerID, stream: stream)
  }

  @discardableResult
  func completeCamera(_ reservation: Reservation, active: Bool) -> Bool {
    Self.registry.completeCamera(reservation, active: active)
  }

  func cancelCamera(_ reservation: Reservation) {
    Self.registry.cancelCamera(reservation)
  }

  @discardableResult
  func completeScreenStart(_ reservation: Reservation) -> Bool {
    Self.registry.completeScreenStart(reservation)
  }

  func failScreenStart(_ reservation: Reservation) {
    Self.registry.failScreenStart(reservation)
  }

  func isValid(_ reservation: Reservation) -> Bool {
    Self.registry.isValid(reservation)
  }

  func beginScreenStop() -> Reservation? {
    Self.registry.beginScreenStop(ownerID: ownerID)
  }

  func beginScreenStop(for startReservation: Reservation) -> Reservation? {
    Self.registry.beginScreenStop(
      ownerID: ownerID,
      startReservation: startReservation)
  }

  func finishScreenStop(_ reservation: Reservation, stopped: Bool) {
    Self.registry.finishScreenStop(reservation, stopped: stopped)
  }

  func releaseCamera() {
    Self.registry.releaseCamera(ownerID: ownerID)
  }

  func revoke() {
    Self.registry.revoke(ownerID: ownerID)
  }

  static func hasScreenReservation(for stream: MediaStream?) -> Bool {
    registry.hasScreenReservation(for: stream)
  }

  static func releaseCameraReservations(
    for stream: MediaStream,
    excluding reservation: Reservation? = nil
  ) {
    registry.releaseCameraReservations(
      for: stream,
      excluding: reservation?.ownerID)
  }
}

/// SDK と公開 API が行うプロセス全体のカメラ操作を、完了コールバックまで含めて直列化します。
///
/// クリーンアップが失敗した場合はカメラを隔離状態にし、動作状態が不明なまま別接続が
/// start / restart を実行することを防ぎます。停止成功を確認した場合だけ隔離を解除します。
///
/// `@unchecked Sendable` としているのは、可変状態が `quarantinedCapturerID` だけで、
/// その読み書きをすべて `lock` で排他しているためです。`owner` と `operationQueue` は
/// `let` で、queue 側が操作を直列化します。
final class CameraVideoCaptureCoordinator: @unchecked Sendable {
  static let shared = CameraVideoCaptureCoordinator()

  /// 隔離状態の唯一の保持先であるカメラ状態 owner です。
  ///
  /// 注入した owner を使うのは `isAvailable` / `cameraOperationRejectionError` の判定と、
  /// `quarantine` / `clearQuarantineAfterSuccessfulStop` が送る `.quarantined` /
  /// `.quarantineCleared` の適用先です。reducer の他の state、instance テーブル、pin は
  /// `CameraVideoCapturer` が常に `CameraStateOwner.shared` を参照するため
  /// process-wide な owner に作られます。
  private let owner: CameraStateOwner

  private let operationQueue = SerializedAsyncOperationQueue()
  private let lock = NSLock()
  private var quarantinedCapturerID: CameraCapturerID?

  /// owner を指定して coordinator を初期化します。
  ///
  /// 既定は process-wide な `CameraStateOwner.shared` です。テストでは shared を
  /// 汚染しないよう、テストローカルの owner を渡します。
  init(owner: CameraStateOwner = .shared) {
    self.owner = owner
  }

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
  ///
  /// 隔離状態は owner の `phase` が保持します。coordinator はキャッシュを持たず、
  /// owner の snapshot を参照します。lock を取らないため、`quarantine` /
  /// `clearQuarantineAfterSuccessfulStop` の更新より前に true を観測し得ますが、
  /// 隔離の判定と操作はすべて coordinator の直列 queue 上で行う前提のため問題に
  /// なりません。また停止要求は phase を `.quarantined` から外すため、隔離中の
  /// 回復停止が実行されている間は true を返します (この間も操作は直列化される)。
  var isAvailable: Bool {
    owner.snapshot.phase != .quarantined
  }

  /// クリーンアップ失敗を記録し、以後の start / restart を拒否します。
  ///
  /// 実際の停止を再試行できるよう、停止に失敗した capturer の ID を保持します。
  /// 停止対象が特定できない場合は ID を保持しません。
  /// ID の更新と owner への通知を同じ lock 区間で行い、別のスレッドの解除に
  /// 割り込まれて新しい隔離が解除されないようにします。
  func quarantine(capturerID: CameraCapturerID? = nil) {
    lock.lock()
    defer { lock.unlock() }
    if let capturerID {
      quarantinedCapturerID = capturerID
    }
    owner.handle(.quarantined)
  }

  /// 実際の停止成功を確認した後に隔離状態を解除します。
  ///
  /// 隔離した capturer が指定と異なる場合は解除しません (別接続の停止完了で
  /// 隔離を解除しないため)。照合・解除・ owner への通知を同じ lock 区間で行います。
  func clearQuarantineAfterSuccessfulStop(capturerID: CameraCapturerID? = nil) {
    lock.lock()
    defer { lock.unlock() }
    if let trackedID = quarantinedCapturerID, trackedID != capturerID {
      return
    }
    quarantinedCapturerID = nil
    owner.handle(.quarantineCleared)
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

/// `CameraVideoCapturerHandlers` を lock 付きで保持する storage です。
///
/// `handlers` の get / set を保護します。利用者の
/// `CameraVideoCapturer.handlers.onCapture = ...` という in-place 変更は
/// 同じインスタンスを返すことで維持します。
///
/// `@unchecked Sendable` としているのは、可変状態が `handlers` だけで、その読み書きを
/// すべて `lock` で排他しているためです。返した `CameraVideoCapturerHandlers` が持つ
/// closure property 自体の読み書きは、この lock では排他しません。
private final class CameraHandlersStorage: @unchecked Sendable {
  private let lock = NSLock()
  private var handlers = CameraVideoCapturerHandlers()

  /// 現在の handlers を返します。
  func current() -> CameraVideoCapturerHandlers {
    lock.lock()
    defer { lock.unlock() }
    return handlers
  }

  /// handlers を差し替えます。
  func publish(_ handlers: CameraVideoCapturerHandlers) {
    lock.lock()
    defer { lock.unlock() }
    self.handlers = handlers
  }
}

/// non-Sendable な `AVCaptureDevice` を lock 付きで保持する storage です。
///
/// `device` の getter / setter と `position` はこの storage の lock 下で読み書きし、
/// owner の queue を同期 wait しません。owner の command は command 開始時に
/// libwebrtc の capture session queue 上でこの storage から読み取ります。
///
/// `@unchecked Sendable` としているのは、可変状態が `device` だけで、その読み書きを
/// すべて `lock` で排他しているためです。
private final class CameraDeviceStorage: @unchecked Sendable {
  private let lock = NSLock()
  private var device: AVCaptureDevice

  init(device: AVCaptureDevice) {
    self.device = device
  }

  /// 現在のデバイスを返します。
  func current() -> AVCaptureDevice {
    lock.lock()
    defer { lock.unlock() }
    return device
  }

  /// デバイスを差し替えます。
  func setDevice(_ device: AVCaptureDevice) {
    lock.lock()
    defer { lock.unlock() }
    self.device = device
  }
}

/// non-Sendable な `RTCCameraVideoCapturer` とその delegate を保持する storage です。
///
/// どちらも init で確定し以後差し替えないため、保持するだけで安全に共有できます。
/// native の呼び出しは libwebrtc の capture session queue 上で行います。
///
/// `@unchecked Sendable` としているのは、保持する値が init で確定した `let` だけで、
/// 可変状態を持たないためです。
private final class CameraNativeStorage: @unchecked Sendable {
  private let native: RTCCameraVideoCapturer
  private let delegate: CameraVideoCapturerDelegate

  init(native: RTCCameraVideoCapturer, delegate: CameraVideoCapturerDelegate) {
    self.native = native
    self.delegate = delegate
  }

  /// `RTCCameraVideoCapturer` を返します。
  func nativeCapturer() -> RTCCameraVideoCapturer {
    native
  }

  /// `AVCaptureSession` を返します。
  func captureSession() -> AVCaptureSession {
    native.captureSession
  }
}

/// libwebrtc の capture session queue への hop を 1 箇所に閉じ込める adapter です。
///
/// `RTCCameraVideoCapturer` の native 操作と delegate callback は libwebrtc の
/// capture session queue 上でのみ行う必要があります。カメラ操作はこの adapter を
/// 経由してのみ queue へ hop し、公開 dispatcher API には依存しません。
enum CameraQueueExecutor {
  /// capture session queue 上で block を非同期で実行します。
  static func async(_ block: @escaping () -> Void) {
    RTCDispatcher.dispatchAsync(on: .typeCaptureSession, block: block)
  }
}

/// カメラをキャプチャするクラスです。
///
/// 解像度やフレームレートなどの設定は `start` 実行時に指定します。
/// カメラはパブリッシャーまたはグループの接続時に自動的に起動 (起動済みなら再起動) されます。
///
/// カメラの設定を変更したい場合は、 `change` を実行します。
///
/// 共有状態は `CameraStateOwner` が、`device` は instance ごとの lock 付き storage が、
/// `handlers` は型全体で共有する lock 付き storage (`private static let handlersStorage`) が
/// 保持します。この型が持つ instance の stored property は次の 3 つだけです。
///
/// - `id`: instance を識別する ID
/// - `deviceStorage`: `AVCaptureDevice` を保持する lock 付き storage
/// - `nativeStorage`: `RTCCameraVideoCapturer` とその delegate を保持する storage
///
/// 不変条件は次のとおりです。`RTCCameraVideoCapturer` の start / stop と
/// `AVCaptureDevice` の使用は libwebrtc の capture session queue 上でのみ行います。
/// camera queue への hop は `CameraQueueExecutor` に閉じ込めており、`start` / `stop` /
/// `restart` / `change` / `flip` はすべてこの queue を経由します。
/// frame callback (`CameraVideoCapturerDelegate.capturer(_:didCapture:)`) も
/// libwebrtc の capture session queue 上で発火する前提とします (upstream の実装を
/// 確認できないため、現行の挙動を前提とします)。
///
/// 一方で `current` / `isRunning` / `format` / `frameRate` は owner の snapshot と
/// resource テーブルから、`stream` は owner の resource テーブルから (弱参照のため
/// capturer は `MediaStream` を保持しません)、`device` / `handlers` / `position` は
/// instance の lock 付き storage から、`captureSession` は init で確定して以後
/// 差し替えない storage から読むため、任意のスレッドから呼べます。`device` の setter も
/// 任意のスレッドから呼べるため、command の実行中に device を差し替えると、その command が
/// 読む device は差し替え前後で変わり得ます。
/// `handlers` の get / set が排他するのは bag の参照だけであり、closure property 自体の
/// 同時アクセスは排他していません。
///
/// `Sendable` に準拠するのは、共有状態を owner が、non-Sendable な実資源を
/// lock 付き storage が保持しているためです。
public final class CameraVideoCapturer: Sendable {
  /// この instance を識別する ID です。
  ///
  /// owner の instance テーブルへの登録と、状態機械の command 引数に使います。
  /// `init` の全 stored property を初期化した後に owner へ登録します。
  let id = CameraCapturerID()

  // MARK: インスタンスの取得

  /// 利用可能なデバイスのリスト
  /// RTCCameraVideoCapturer.captureDevices を返します。
  public static var devices: [AVCaptureDevice] { RTCCameraVideoCapturer.captureDevices() }

  /// 前面のカメラに対応するデバイス
  ///
  /// owner が instance を 1 つだけ遅延生成して強参照で保持し、2 回目以降は同じ instance を
  /// 返します。`public static let` のままだと `@unchecked Sendable` の除去後に
  /// non-Sendable 型の static let になり Swift 6 でエラーになるため computed property と
  /// しています。
  public static var front: CameraVideoCapturer? {
    CameraStateOwner.shared.frontCapturer()
  }

  /// 背面のカメラに対応するデバイス
  public static var back: CameraVideoCapturer? {
    CameraStateOwner.shared.backCapturer()
  }

  /// 起動中のデバイス
  ///
  /// owner の snapshot を読みます。書き込みは owner の publish へ一本化するため
  /// setter は設けません (外部からは従来どおり読み取り専用)。
  public static var current: CameraVideoCapturer? {
    CameraStateOwner.shared.currentCapturer
  }

  /// RTCCameraVideoCapturer が保持している AVCaptureSession
  public var captureSession: AVCaptureSession { nativeStorage.captureSession() }

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
  /// 連続実行時の競合は owner の state が持つ flip 実行中フラグで防ぎます。
  /// 引数には CameraVideoCapturer.current を渡してください。
  public static func flip(
    _ capturer: CameraVideoCapturer, completionHandler: @escaping ((Error?) -> Void)
  ) {
    let coordinator = CameraVideoCaptureCoordinator.shared
    let completionBox = CameraOperationCompletionBox(completionHandler)
    coordinator.enqueue {
      if let error = CameraVideoCapturer.cameraOperationRejectionError(
        coordinator: coordinator, stream: capturer.stream)
      {
        completionBox(error)
        return
      }
      _ = await flipForSDK(capturer, completionBeforeEvent: completionBox)
    }
  }

  /// 共有 coordinator から呼び出す、直列化されていないカメラ切り替え処理です。
  private static func flipUncoordinated(
    _ capturer: CameraVideoCapturer, completionHandler: @escaping ((Error?) -> Void)
  ) {
    // camera queue (libwebrtc の capture session queue) で直列化する。
    // 連続した flip (フリップボタンの連続タップ等) が同時に実行され、
    // stop / start の callback が入れ替わる競合を防ぐ。
    CameraQueueExecutor.async {
      // 引数が現在の capturer と一致することを確認する。
      // (別の capturer を渡すと、停止していない capturer への stop / stream 代入が起こるため)
      guard capturer === CameraVideoCapturer.current else {
        completionHandler(
          SoraError.cameraError(reason: "capturer is not the current camera"))
        return
      }

      // 既に flip が実行中の場合はエラーを返す (re-entrance 防止)。
      // owner の state が持つ flip 実行中フラグで判定する。
      if CameraStateOwner.shared.snapshot.isFlipping {
        completionHandler(
          SoraError.cameraError(reason: "camera flip is already in progress"))
        return
      }

      guard let format = capturer.format else {
        completionHandler(SoraError.cameraError(reason: "format should not be nil"))
        return
      }

      guard let capturerFrameRate = capturer.frameRate else {
        completionHandler(SoraError.cameraError(reason: "frameRate should not be nil"))
        return
      }

      // 反対の position を持つ CameraVideoCapturer を取得します。
      guard let flip: CameraVideoCapturer = (capturer.device.position == .front ? .back : .front)
      else {
        let name = capturer.device.position == .front ? "back" : "front"
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
        completionHandler(
          SoraError.cameraError(
            reason: "CameraVideoCapturer.format failed: suitable format is not found"))
        return
      }

      guard let frameRate = CameraVideoCapturer.maxFrameRate(capturerFrameRate, for: format)
      else {
        completionHandler(
          SoraError.cameraError(
            reason:
              "CameraVideoCapturer.maxFramerate failed: suitable frameRate is not found"))
        return
      }

      let owner = CameraStateOwner.shared
      let generation = owner.nextGeneration()

      // 切り替え先の stream を start より前に設定する。
      // (元の capturer が保持する stream を引き継ぐ)
      // start 失敗時は compare-and-swap で rollback する。
      // (command 実行中に利用者が代入していた値は破壊しない)
      let originalStream = flip.stream
      let newStream = capturer.stream
      flip.stream = newStream

      Logger.debug(
        type: .cameraVideoCapturer,
        message: "starting flip to \(flip.device)")

      owner.handle(
        .flipRequested(
          sourceID: capturer.id, targetID: flip.id, generation: generation))

      // 内部の stop は .stopCompleted として owner へ反映し、 start の完了だけを
      // 複合コマンドの完了として返す。
      let finish: (Error?) -> Void = { error in
        if error != nil {
          // command が最後に書いた値が残っている場合だけ rollback する。
          owner.compareAndSetStream(newStream, to: originalStream, id: flip.id)
          Logger.error(
            type: .cameraVideoCapturer,
            message: "failed to flip capturer: \(String(describing: error))")
        } else {
          // 使用した format と frameRate は start 成功時にだけ記録する。
          owner.setFormat(format, id: flip.id)
          owner.handle(
            .formatResolved(id: flip.id, frameRate: frameRate, generation: generation))
          Logger.debug(
            type: .cameraVideoCapturer,
            message: "succeeded to flip to \(flip.device)")
        }
        owner.handle(
          .flipCompleted(
            sourceID: capturer.id, targetID: flip.id, generation: generation,
            success: error == nil))
        completionHandler(error)
        // 利用者 handler は owner の critical section の外で呼ぶ。
        // start に成功した場合のみ onStart を呼ぶ。
        if error == nil {
          CameraVideoCapturer.handlers.onStart?(flip)
        }
      }

      capturer.stopNative {
        // 切り替え元の内部 stop の完了を owner へ反映する。
        // (この時点で切り替え元の current / isRunning が解除される)
        owner.handle(.stopCompleted(id: capturer.id, generation: generation))
        // 切り替え先の start を要求した後に、切り替え元の onStop を呼ぶ。
        // (単体の stop の完了通知と同じ位置で呼ぶ)
        flip.startNative(format: format, frameRate: frameRate) { error in
          if error != nil {
            // 現行と同じエラー表現を維持する。
            finish(SoraError.cameraError(reason: "CameraVideoCapturer.start failed"))
          } else {
            finish(nil)
          }
        }
        CameraVideoCapturer.handlers.onStop?(capturer)
      }
    }
  }

  // MARK: プロパティ

  /// 出力先のストリーム
  ///
  /// owner の resource テーブルへ同期で読み書きします。owner の queue を
  /// 同期 wait しないため、libwebrtc の capture session queue 上からの代入でも
  /// deadlock しません。
  public var stream: MediaStream? {
    get { CameraStateOwner.shared.stream(id: id) }
    set { CameraStateOwner.shared.setStream(newValue, id: id) }
  }

  /// カメラが起動中であれば ``true``
  ///
  /// owner の snapshot から読みます。更新は owner の reducer 経由で行います。
  public var isRunning: Bool {
    CameraStateOwner.shared.isRunning(id: id)
  }

  /// イベントハンドラ
  ///
  /// lock 付き storage から同一インスタンスを返します。利用者の
  /// `CameraVideoCapturer.handlers.onCapture = ...` という in-place 変更を維持します。
  public static var handlers: CameraVideoCapturerHandlers {
    get { handlersStorage.current() }
    set { handlersStorage.publish(newValue) }
  }

  /// handlers を保持する lock 付き storage
  private static let handlersStorage = CameraHandlersStorage()

  /// カメラの位置
  public var position: AVCaptureDevice.Position {
    device.position
  }

  /// 使用中のデバイス
  ///
  /// lock 付き storage から同期で読み書きします。owner の queue を同期 wait しません。
  public var device: AVCaptureDevice {
    get { deviceStorage.current() }
    set { deviceStorage.setDevice(newValue) }
  }

  /// `device` を保持する lock 付き storage
  private let deviceStorage: CameraDeviceStorage

  /// フレームレート
  ///
  /// owner の snapshot から読みます。更新は owner の reducer 経由で行います。
  public var frameRate: Int? {
    CameraStateOwner.shared.frameRate(id: id)
  }

  /// フォーマット
  ///
  /// `AVCaptureDevice.Format` は non-Sendable のため owner の resource テーブルが
  /// 保持し、ここから lock 付きで読み出します。更新はカメラ操作が resource テーブルへ
  /// 同期で行います (`frameRate` は reducer の state が保持します)。
  public var format: AVCaptureDevice.Format? {
    CameraStateOwner.shared.format(id: id)
  }

  /// native と delegate を保持する lock 付き storage
  private let nativeStorage: CameraNativeStorage

  /// 引数に指定した device を利用して CameraVideoCapturer を初期化します。
  /// 自動的に初期化される静的プロパティ、 front/back を定義しています。
  /// 上記以外のデバイスを利用したい場合のみ CameraVideoCapturer を生成してください。
  public init(device: AVCaptureDevice) {
    self.deviceStorage = CameraDeviceStorage(device: device)
    let delegate = CameraVideoCapturerDelegate()
    let native = RTCCameraVideoCapturer(delegate: delegate)
    self.nativeStorage = CameraNativeStorage(native: native, delegate: delegate)

    // 全 stored property の初期化後に delegate と owner へ self を渡す。
    // (初期化前に self を渡せないため、ID は自身で採番している)
    delegate.cameraVideoCapturer = self
    CameraStateOwner.shared.register(id: id, instance: self)
  }

  deinit {
    // instance が解放されたら owner の資源と state を破棄する。
    // (owner が process-wide のため、放置すると format と frameRate が残り続ける)
    CameraStateOwner.shared.release(id: id)
  }

  // MARK: カメラの操作

  /// カメラ操作を開始してよいかを確認し、拒否する場合はエラーを返します。
  ///
  /// 隔離中 (クリーンアップ失敗後) と、対象の stream に画面共有が予約されている場合は
  /// 操作を拒否します。`flip` / `start` / `restart` / `change` が共通で使います。
  /// 判定順は隔離 → 画面共有で、隔離中は画面共有の予約を確認しません。
  /// 隔離の判定は引数の coordinator が保持する owner を参照するため、
  /// テストからも同じ経路を検証できます。
  static func cameraOperationRejectionError(
    coordinator: CameraVideoCaptureCoordinator,
    stream: MediaStream?
  ) -> Error? {
    guard coordinator.isAvailable else {
      return SoraError.cameraError(
        reason: "camera capture is quarantined after a cleanup failure")
    }
    guard !VideoSourceCoordinator.hasScreenReservation(for: stream) else {
      return SoraError.cameraError(reason: "screen capture is active on the camera stream")
    }
    return nil
  }

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
      if let error = CameraVideoCapturer.cameraOperationRejectionError(
        coordinator: coordinator, stream: self.stream)
      {
        completionBox(error)
        return
      }
      guard CameraVideoCapturer.current == nil else {
        completionBox(SoraError.cameraError(reason: "another camera is already running"))
        return
      }
      _ = await self.startForSDK(
        format: formatBox.format,
        frameRate: frameRate,
        senderStream: nil,
        completionBeforeEvent: completionBox)
    }
  }

  /// 共有 coordinator から呼び出す、直列化されていないカメラ開始処理です。
  ///
  /// owner の command として `.startRequested` → `.startCompleted` を適用し、
  /// native start が成功した場合だけ `.formatResolved` で format と frameRate を記録します。
  /// generation はここで採番し、古い callback は owner が破棄します。
  private func startUncoordinated(
    format: AVCaptureDevice.Format,
    frameRate: Int,
    completionHandler: @escaping ((Error?) -> Void)
  ) {
    guard isRunning == false else {
      completionHandler(SoraError.cameraError(reason: "isRunning should be false"))
      return
    }

    let owner = CameraStateOwner.shared
    let generation = owner.nextGeneration()
    owner.handle(.startRequested(id: id, generation: generation))

    startNative(format: format, frameRate: frameRate) { [self] error in
      // 使用した format と frameRate は start 成功時にだけ記録する。
      // (失敗時に要求値を残すと、失敗した設定値が format / frameRate として観測される)
      if error == nil {
        owner.setFormat(format, id: id)
        owner.handle(.formatResolved(id: id, frameRate: frameRate, generation: generation))
      }
      // owner の state を reducer 経由で更新する。
      // (isRunning / current / phase はここで確定する)
      owner.handle(.startCompleted(id: id, generation: generation, success: error == nil))
      completionHandler(error)
      if error == nil {
        CameraVideoCapturer.handlers.onStart?(self)
      }
    }
  }

  /// native のカメラ開始のみを行います (owner の state は更新しません)。
  ///
  /// restart / change / flip のような複合コマンドが、内部の start として使います。
  /// 「動作中でない」ことは、単体の start では `startUncoordinated` が確認し、
  /// 複合コマンドでは内部 stop の完了で動作中から外れていることを前提にします。
  private func startNative(
    format: AVCaptureDevice.Format,
    frameRate: Int,
    completionHandler: @escaping ((Error?) -> Void)
  ) {
    nativeStorage.nativeCapturer().startCapture(
      with: device,
      format: format,
      fps: frameRate
    ) { [self] (error: Error?) in
      if error == nil {
        Logger.debug(
          type: .cameraVideoCapturer,
          message: "succeeded to start \(device) with \(format), \(frameRate)fps")
      }
      completionHandler(error)
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
    let stopCompletionBox = CameraOperationCompletionBox { [self] error in
      // libwebrtc の stopCapture の完了ハンドラーは成否を受け取らず、AVCaptureSession の
      // 停止にもエラー通知が無い。停止できなかったという結果を知る手段が無いため、
      // 停止完了の通知が届いたことを根拠に、停止できたものとして隔離を解除し予約を解放する。
      coordinator.clearQuarantineAfterSuccessfulStop(capturerID: self.id)
      if let stream {
        VideoSourceCoordinator.releaseCameraReservations(for: stream)
      }
      completionBox(error)
    }
    coordinator.enqueue {
      guard CameraVideoCapturer.current === self else {
        if self.isRunning {
          coordinator.quarantine(capturerID: self.id)
        }
        completionBox(SoraError.cameraError(reason: "capturer is not the current camera"))
        return
      }

      _ = await self.stopForSDK(completionBeforeEvent: stopCompletionBox)
    }
  }

  /// 共有 coordinator から呼び出す、直列化されていないカメラ停止処理です。
  ///
  /// owner の command として `.stopRequested` → `.stopCompleted` を適用します。
  private func stopUncoordinated(completionHandler: @escaping ((Error?) -> Void)) {
    guard isRunning else {
      completionHandler(SoraError.cameraError(reason: "isRunning should be true"))
      return
    }

    let owner = CameraStateOwner.shared
    let generation = owner.nextGeneration()
    owner.handle(.stopRequested(id: id, generation: generation))

    stopNative { [self] in
      // owner の state を reducer 経由で更新する。
      // (native の停止は成否を返さないため、`.stopCompleted` は success を持たず、
      // 停止完了の通知を停止成功として扱う)
      owner.handle(.stopCompleted(id: id, generation: generation))
      completionHandler(nil)
      CameraVideoCapturer.handlers.onStop?(self)
    }
  }

  /// native のカメラ停止のみを行います (owner の state は更新しません)。
  ///
  /// restart / change / flip のような複合コマンドが、内部の stop として使います。
  private func stopNative(completionHandler: @escaping (() -> Void)) {
    nativeStorage.nativeCapturer().stopCapture { [self] in
      Logger.debug(
        type: .cameraVideoCapturer,
        message: "succeeded to stop \(String(describing: device))")
      completionHandler()
    }
  }

  /// 停止前と同じ設定でカメラを再起動します。
  public func restart(completionHandler: @escaping ((Error?) -> Void)) {
    let coordinator = CameraVideoCaptureCoordinator.shared
    let completionBox = CameraOperationCompletionBox(completionHandler)
    coordinator.enqueue {
      if let error = CameraVideoCapturer.cameraOperationRejectionError(
        coordinator: coordinator, stream: self.stream)
      {
        completionBox(error)
        return
      }
      let current = CameraVideoCapturer.current
      guard current == nil || current === self else {
        completionBox(SoraError.cameraError(reason: "another camera is already running"))
        return
      }
      guard !self.isRunning || current === self else {
        coordinator.quarantine(capturerID: self.id)
        completionBox(SoraError.cameraError(reason: "capturer is not the current camera"))
        return
      }
      _ = await self.restartForSDK(
        senderStream: nil,
        completionBeforeEvent: completionBox)
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

    let owner = CameraStateOwner.shared
    let generation = owner.nextGeneration()
    // 内部 stop の要否はイベント適用より先に確定する。
    // (.restartRequested は実行中の状態を変えないが、将来の変更に依存しない)
    let wasRunning = isRunning
    owner.handle(.restartRequested(id: id, generation: generation))

    // 内部 stop は .stopCompleted として owner へ反映し、 start の完了だけを
    // 複合コマンドの完了として返す。
    let finish: (Error?) -> Void = { [self] error in
      // 使用した format と frameRate は start 成功時にだけ記録する。
      if error == nil {
        owner.setFormat(format, id: id)
        owner.handle(.formatResolved(id: id, frameRate: frameRate, generation: generation))
        Logger.debug(type: .cameraVideoCapturer, message: "succeeded to restart")
      }
      owner.handle(.restartCompleted(id: id, generation: generation, success: error == nil))
      completionHandler(error)
      // 利用者 handler は owner の critical section の外で呼ぶ。
      // start に成功した場合のみ onStart を呼ぶ。
      if error == nil {
        CameraVideoCapturer.handlers.onStart?(self)
      }
    }

    if wasRunning {
      stopNative { [self] in
        // 内部 stop の完了により current / isRunning が解除される。
        owner.handle(.stopCompleted(id: id, generation: generation))
        // native start を要求した後に onStop を呼ぶ。
        // (単体の stop の完了通知と同じ位置で呼ぶ)
        startNative(format: format, frameRate: frameRate) { error in
          finish(error)
        }
        CameraVideoCapturer.handlers.onStop?(self)
      }
    } else {
      startNative(format: format, frameRate: frameRate) { error in
        finish(error)
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
      if let error = CameraVideoCapturer.cameraOperationRejectionError(
        coordinator: coordinator, stream: self.stream)
      {
        completionBox(error)
        return
      }
      guard CameraVideoCapturer.current === self else {
        completionBox(SoraError.cameraError(reason: "capturer is not the current camera"))
        return
      }
      _ = await self.changeForSDK(
        format: formatBox?.format,
        frameRate: frameRate,
        completionBeforeEvent: completionBox)
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

    let owner = CameraStateOwner.shared
    let generation = owner.nextGeneration()
    owner.handle(.changeRequested(id: id, generation: generation))

    let finish: (Error?) -> Void = { [self] error in
      // 使用した format と frameRate は start 成功時にだけ記録する。
      if error == nil {
        owner.setFormat(format, id: id)
        owner.handle(.formatResolved(id: id, frameRate: frameRate, generation: generation))
        Logger.debug(type: .cameraVideoCapturer, message: "succeeded to change")
      }
      owner.handle(.changeCompleted(id: id, generation: generation, success: error == nil))
      completionHandler(error)
      // 利用者 handler は owner の critical section の外で呼ぶ。
      // start に成功した場合のみ onStart を呼ぶ。
      if error == nil {
        CameraVideoCapturer.handlers.onStart?(self)
      }
    }

    stopNative { [self] in
      // 内部 stop の完了により current / isRunning が解除される。
      owner.handle(.stopCompleted(id: id, generation: generation))
      // native start を要求した後に onStop を呼ぶ。
      // (単体の stop の完了通知と同じ位置で呼ぶ)
      startNative(format: format, frameRate: frameRate) { error in
        finish(error)
      }
      CameraVideoCapturer.handlers.onStop?(self)
    }
  }

}

extension CameraVideoCapturer {
  /// SDK のカメラキュー上で起動し、完了時のエラーを返します。
  func startForSDK(
    format: AVCaptureDevice.Format,
    frameRate: Int,
    senderStream: SenderStreamBox?,
    completionBeforeEvent: CameraOperationCompletionBox? = nil
  ) async -> Error? {
    await withCheckedContinuation { continuation in
      CameraQueueExecutor.async {
        // start の完了前からフレームが届く場合があるため、先に送信先を設定する。
        let originalStream = self.stream
        if let senderStream {
          self.stream = senderStream.stream
        }
        self.startUncoordinated(format: format, frameRate: frameRate) { error in
          if error != nil, let senderStream {
            // command が最後に書いた値が残っている場合だけ rollback する。
            CameraStateOwner.shared.compareAndSetStream(
              senderStream.stream, to: originalStream, id: self.id)
          }
          completionBeforeEvent?(error)
          continuation.resume(returning: error)
        }
      }
    }
  }

  /// SDK のカメラキュー上で停止し、完了時のエラーを返します。
  func stopForSDK(
    completionBeforeEvent: CameraOperationCompletionBox? = nil
  ) async -> Error? {
    await withCheckedContinuation { continuation in
      CameraQueueExecutor.async {
        self.stopUncoordinated { error in
          completionBeforeEvent?(error)
          continuation.resume(returning: error)
        }
      }
    }
  }

  /// SDK のカメラキュー上で再起動し、完了時のエラーを返します。
  func restartForSDK(
    senderStream: SenderStreamBox?,
    completionBeforeEvent: CameraOperationCompletionBox? = nil
  ) async -> Error? {
    await withCheckedContinuation { continuation in
      CameraQueueExecutor.async {
        let originalStream = self.stream
        if let senderStream {
          self.stream = senderStream.stream
        }
        self.restartUncoordinated { error in
          if error != nil, let senderStream {
            // command が最後に書いた値が残っている場合だけ rollback する。
            CameraStateOwner.shared.compareAndSetStream(
              senderStream.stream, to: originalStream, id: self.id)
          }
          completionBeforeEvent?(error)
          continuation.resume(returning: error)
        }
      }
    }
  }

  /// SDK のカメラキュー上で設定を変更し、完了時のエラーを返します。
  func changeForSDK(
    format: AVCaptureDevice.Format?,
    frameRate: Int?,
    completionBeforeEvent: CameraOperationCompletionBox? = nil
  ) async -> Error? {
    await withCheckedContinuation { continuation in
      CameraQueueExecutor.async {
        self.changeUncoordinated(format: format, frameRate: frameRate) { error in
          completionBeforeEvent?(error)
          continuation.resume(returning: error)
        }
      }
    }
  }

  /// SDK のカメラキュー上でカメラを切り替え、完了時のエラーを返します。
  static func flipForSDK(
    _ capturer: CameraVideoCapturer,
    completionBeforeEvent: CameraOperationCompletionBox? = nil
  ) async -> Error? {
    await withCheckedContinuation { continuation in
      CameraVideoCapturer.flipUncoordinated(capturer) { error in
        completionBeforeEvent?(error)
        continuation.resume(returning: error)
      }
    }
  }
}

/// `CameraVideoCapturer` の設定を表すオブジェクトです。
public struct CameraSettings: CustomStringConvertible, Sendable {
  /// デフォルトの設定。
  public static var `default`: CameraSettings { CameraSettings() }

  /// `CameraVideoCapturer` で使用する映像解像度を表す enum です。
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

  /// CameraVideoCapturer.start(format:frameRate:completionHandler) の completionHandler の後に実行されます。
  /// また CameraVideoCapturer.restart(completionHandler) /
  /// CameraVideoCapturer.change(format:frameRate:completionHandler) /
  /// CameraVideoCapturer.flip(_:completionHandler) でも、内部の start が成功した場合に呼び出されます。
  /// 内部の start は非同期に開始され、その完了通知は stop の完了通知より後に届くため、
  /// restart / change / flip では onStop の後に onStart が呼ばれます。
  public var onStart: ((CameraVideoCapturer) -> Void)?

  /// CameraVideoCapturer.stop(completionHandler) 内で completionHandler の後に実行されます。
  /// また CameraVideoCapturer.restart(completionHandler) /
  /// CameraVideoCapturer.change(format:frameRate:completionHandler) /
  /// CameraVideoCapturer.flip(_:completionHandler) でも、内部の stop が完了した場合に呼び出されます。
  /// 注意点については、 onStart のコメントを参照してください。
  public var onStop: ((CameraVideoCapturer) -> Void)?

  /// CameraVideoCapturer のイベントハンドラを初期化します。
  public init() {}
}
