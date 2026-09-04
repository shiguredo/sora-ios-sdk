import Foundation
import WebRTC

/// SoraCloseEvent は、Sora の接続が切断された際のイベント情報を表します。
///
/// 接続が正常に切断された場合は、`.ok(code, reason)` ケースが使用され、
/// 異常な切断やエラー発生時は、`.error(Error)` ケースが使用されます。
public enum SoraCloseEvent {
  /// 正常な接続切断を示します。
  /// - Parameters:
  ///   - code: 接続切断時に返されるコード。例えば、WebSocket の標準切断コード（例: 1000 等）など。
  ///   - reason: 接続が正常に切断された理由の説明文字列。
  case ok(code: Int, reason: String)
  /// 異常な切断またはエラーが発生して切断した場合に利用されるケースです。
  /// - Parameter error: エラー情報。
  case error(Error)
}

/// メディアチャネルのイベントハンドラです。
public final class MediaChannelHandlers {
  /// 接続成功時に呼ばれるクロージャー
  public var onConnect: ((Error?) -> Void)?

  /// 接続解除時に呼ばれるクロージャー
  @available(
    *, deprecated,
    message:
      "onDisconnect: ((SoraCloseEvent) -> Void)? に移行してください。onDisconnectLegacy: ((Error?) -> Void)? は、2027 年中に削除予定です。"
  )
  public var onDisconnectLegacy: ((Error?) -> Void)?

  /// 接続解除時に呼ばれるクロージャー
  public var onDisconnect: ((SoraCloseEvent) -> Void)?

  /// ストリームが追加されたときに呼ばれるクロージャー
  public var onAddStream: ((MediaStream) -> Void)?

  /// ストリームが除去されたときに呼ばれるクロージャー
  public var onRemoveStream: ((MediaStream) -> Void)?

  /// シグナリング受信時に呼ばれるクロージャー。
  /// 引数の `String` には、受信したシグナリングメッセージの JSON 文字列が渡されます。
  public var onReceiveSignalingJSON: ((String) -> Void)?

  /// シグナリング受信時に呼ばれるクロージャー
  @available(
    *, deprecated,
    message: "JSON 文字列を受け取る onReceiveSignalingJSON へ移行してください。"
  )
  public var onReceiveSignaling: ((Signaling) -> Void)?

  /// メッセージング用 DataChannel がすべてクライアント側で OPEN になったタイミングで呼ばれるクロージャー。
  /// メッセージング用ラベル（offer の `data_channels` の `#` 始まり）が存在しない場合は発火しない。
  /// この時点ではまだ `type: switched` を受信していない場合があり、
  /// その場合 `sendMessage` は "DataChannel is not open yet" エラーを返す。
  /// 呼び出し元のスレッドは保証されないため、必要に応じて main キューに束ねること。
  public var onDataChannel: ((MediaChannel) -> Void)?

  /// DataChannel がクライアント側で OPEN になったタイミングで、ラベルごとに 1 回呼ばれるクロージャー。
  /// クライアント側で OPEN になったすべての DataChannel（`#` 始まりのラベルに限定しない）が対象。
  /// 呼び出し元のスレッドは保証されないため、必要に応じて main キューに束ねること。
  public var onDataChannelOpened: ((MediaChannel, String) -> Void)?

  /// DataChannel のメッセージ受信時に呼ばれるクロージャー
  public var onDataChannelMessage: ((MediaChannel, String, Data) -> Void)?

  /// 初期化します。
  public init() {}
}

// MARK: -

/// MediaChannel 固有の切断準備と PeerChannel の完了通知を合流させる状態機械です。
/// 呼び出し側は MediaChannel の lifecycle lock を保持した状態で操作します。
struct MediaChannelDisconnectPreparation {
  enum State: Equatable {
    case notStarted
    case running
    case finished
  }

  enum ReceiveResult: Equatable {
    case prepare
    case deferred
    case ready
  }

  struct Completion {
    let connectionTask: ConnectionTask
    let error: Error?
    let reason: DisconnectReason
  }

  private(set) var state: State = .notStarted
  private var pendingCompletion: Completion?

  /// 切断準備を開始できる場合だけ状態を `running` へ進めます。
  mutating func begin() -> Bool {
    guard state == .notStarted else {
      return false
    }
    state = .running
    return true
  }

  /// PeerChannel の完了通知を受け取り、呼び出し側が次に行う処理を返します。
  mutating func receive(_ completion: Completion) -> ReceiveResult {
    switch state {
    case .notStarted:
      state = .running
      pendingCompletion = completion
      return .prepare
    case .running:
      if pendingCompletion == nil {
        pendingCompletion = completion
      }
      return .deferred
    case .finished:
      return .ready
    }
  }

  /// 切断準備を完了し、準備中に保留された完了通知を返します。
  mutating func complete() -> Completion? {
    guard state == .running else {
      return nil
    }
    state = .finished
    let completion = pendingCompletion
    pendingCompletion = nil
    return completion
  }
}

// MARK: -

/// 接続試行の予約から接続タイマー開始までを管理する状態機械です。
/// 呼び出し側は MediaChannel の lifecycle lock を保持した状態で操作します。
struct MediaChannelConnectionTimerAuthorization {
  enum State: Equatable {
    case idle
    case authorized
    case started
    case terminated
  }

  private(set) var state: State = .idle

  /// 接続試行を予約し、後続のタイマー開始を認可します。
  mutating func authorizeConnection() {
    precondition(state == .idle)
    state = .authorized
  }

  /// 認可された接続試行に対して、タイマー開始を 1 回だけ許可します。
  mutating func beginTimer() -> Bool {
    guard state == .authorized else {
      return false
    }
    state = .started
    return true
  }

  /// 接続成功または切断開始により、遅延したタイマー開始を恒久的に拒否します。
  mutating func terminate() {
    state = .terminated
  }
}

// MARK: -

/// 非同期 cleanup の完了通知から MediaChannel を弱参照するための内部ラッパーです。
/// MediaChannel 自体を Sendable とせず、終端処理だけを lifecycle lock 配下へ戻します。
private final class WeakMediaChannelBox: @unchecked Sendable {
  weak var value: MediaChannel?

  init(_ value: MediaChannel) {
    self.value = value
  }
}

// MARK: -

/// 一度接続を行ったメディアチャネルは再利用できません。
/// 同じ設定で接続を行いたい場合は、新しい接続を行う必要があります。
///
/// ## 接続が解除されるタイミング
///
/// メディアチャネルの接続が解除される条件を以下に示します。
/// いずれかの条件が 1 つでも成立すると、メディアチャネルを含めたすべてのチャネル
/// (シグナリングチャネル、ピアチャネル、 WebSocket チャネル) の接続が解除されます。
///
/// - シグナリングチャネル (`SignalingChannel`) の接続が解除される。
/// - WebSocket チャネル (`WebSocketChannel`) の接続が解除される。
/// - ピアチャネル (`PeerChannel`) の接続が解除される。
/// - サーバーから受信したシグナリング `ping` に対して `pong` を返さない。
///   これはピアチャネルの役目です。
public final class MediaChannel {
  // MARK: - イベントハンドラ

  /// イベントハンドラ
  public var handlers = MediaChannelHandlers()

  /// 内部処理で使われるイベントハンドラ
  var internalHandlers = MediaChannelHandlers()

  // MARK: - 接続情報

  /// クライアントの設定
  public let configuration: Configuration

  /// 最初に type: connect メッセージを送信した URL (デバッグ用)
  ///
  /// Sora から type: redirect メッセージを受信した場合、 contactUrl と connectedUrl には異なる値がセットされます
  /// type: redirect メッセージを受信しなかった場合、 contactUrl と connectedUrl には同じ値がセットされます
  public var contactUrl: URL? {
    signalingChannel.contactUrl
  }

  /// 接続中の URL
  public var connectedUrl: URL? {
    signalingChannel.connectedUrl
  }

  /// メディアチャンネルの内部で利用している RTCPeerConnection
  public var native: RTCPeerConnection? {
    peerChannel.nativeChannel
  }

  /// クライアント ID 。接続後にセットされます。
  public var clientId: String? {
    peerChannel.clientId
  }

  /// バンドル ID 。接続後にセットされます。
  public var bundleId: String? {
    peerChannel.bundleId
  }

  /// 接続 ID 。接続後にセットされます。
  public var connectionId: String? {
    peerChannel.connectionId
  }

  /// 接続状態
  public private(set) var state: ConnectionState = .disconnected {
    didSet {
      Logger.trace(
        type: .mediaChannel,
        message: "changed state from \(oldValue) to \(state)")
    }
  }

  /// 接続中 (`state == .connected`) であれば ``true``
  public var isAvailable: Bool { state == .connected }

  /// 接続開始時刻。
  /// 接続中にのみ取得可能です。
  public private(set) var connectionStartTime: Date?

  /// 接続時間 (秒) 。
  /// 接続中にのみ取得可能です。
  public var connectionTime: Int? {
    if let start = connectionStartTime {
      return Int(Date().timeIntervalSince(start))
    } else {
      return nil
    }
  }

  // MARK: 接続中のチャネルの情報

  /// 同チャネルに接続中のクライアントの数。
  /// サーバーから通知を受信可能であり、かつ接続中にのみ取得可能です。
  public private(set) var connectionCount: Int?

  /// 同チャネルに接続中のクライアントのうち、パブリッシャーの数。
  /// サーバーから通知を受信可能であり、接続中にのみ取得可能です。
  public private(set) var publisherCount: Int?

  /// 同チャネルに接続中のクライアントの数のうち、サブスクライバーの数。
  /// サーバーから通知を受信可能であり、接続中にのみ取得可能です。
  public private(set) var subscriberCount: Int?

  // MARK: 接続チャネル

  /// シグナリングチャネル
  let signalingChannel: SignalingChannel

  /// ピアチャネル
  var peerChannel: PeerChannel {
    // init で必ず初期化されるため安全
    // swiftlint:disable:next force_unwrapping
    _peerChannel!
  }

  // PeerChannel に mediaChannel を保持させる際にこの書き方が必要になった
  private var _peerChannel: PeerChannel?

  // MARK: - DataChannel の OPEN 追跡

  /// OPEN になった DataChannel のラベル集合。
  /// `onDataChannelOpened` の発火済みラベル (重複通知の防止用) を兼ねる。
  /// メッセージング用ラベル（`#` 始まり）も必ずここに含まれるため、
  /// `onDataChannel` の一括通知判定 (全メッセージング用ラベルが OPEN になったか) にも利用する。
  private var openedDataChannelLabels: Set<String> = []

  /// メッセージング用ラベル（offer の `data_channels` の `#` 始まり）の集合。
  /// offer 受信時 (resetDataChannelNotificationState 経由) に更新される。
  /// リダイレクト等で offer が再送された場合は常に最新の offer を基準に判定できる。
  private var messagingLabels: Set<String> = []

  /// `onDataChannel` の一括通知済みフラグ
  private var onDataChannelNotified = false

  /// DataChannel の OPEN 追跡状態を保護するロック。
  /// 状態の更新は libwebrtc の delegate スレッド (DataChannel の状態通知) と
  /// WebSocket 受信スレッド (offer 受信時のリセット) から並行して行われるため、
  /// NSLock で排他する。ハンドラ呼び出しはロックの外で行うこと。
  private let dataChannelOpenLock = NSLock()

  /// ストリームのリスト
  public var streams: [MediaStream] {
    peerChannel.streams
  }
  /// 最初のストリーム。
  /// マルチストリームでは、必ずしも最初のストリームが 送信ストリームとは限りません。
  /// 送信ストリームが必要であれば `senderStream` を使用してください。
  public var mainStream: MediaStream? {
    streams.first
  }

  /// 送信に使われるストリーム。
  /// ストリーム ID が `configuration.publisherStreamId` に等しいストリームを返します。
  public var senderStream: MediaStream? {
    streams.first { stream in
      stream.streamId == configuration.publisherStreamId
    }
  }

  /// 受信ストリームのリスト。
  /// ストリーム ID が `configuration.publisherStreamId` と異なるストリームを返します。
  public var receiverStreams: [MediaStream] {
    streams.filter { stream in
      stream.streamId != configuration.publisherStreamId
    }
  }

  private var connectionTimer: ConnectionTimer {
    // init で必ず初期化されるため安全
    // swiftlint:disable:next force_unwrapping
    _connectionTimer!
  }

  /// 接続タイマーの終端状態を回帰テストから確認するための内部アクセサーです。
  var isConnectionTimerRunning: Bool {
    connectionTimer.isRunning
  }

  // PeerChannel に mediaChannel を保持させる際にこの書き方が必要になった
  private var _connectionTimer: ConnectionTimer?

  private let nativePeerChannelFactory: NativePeerChannelFactory

  /// 接続開始、接続成功、切断開始、切断完了の競合を直列化します。
  /// 利用者のハンドラーは、このロックを保持した状態では呼び出しません。
  private let connectionLifecycleLock = NSLock()

  /// 現在の接続試行に対応する ConnectionTask です。
  private var currentConnectionTask: ConnectionTask?

  /// 一度開始した MediaChannel の再利用を拒否するためのフラグです。
  private var hasStartedConnection = false

  /// 接続試行の予約後に遅れて到着するタイマー開始を、切断終端後は拒否します。
  private var connectionTimerAuthorization = MediaChannelConnectionTimerAuthorization()

  /// 切断開始時点が接続試行中だったかを保持します。
  /// PeerChannel の実切断完了時に接続結果ハンドラーを発火するかの判定に使います。
  private var disconnectStartedWhileConnecting = false

  private var disconnectPreparation = MediaChannelDisconnectPreparation()

  /// PeerChannel から重複して切断完了が通知されても、公開通知を 1 回に抑えます。
  private var disconnectFinished = false

  // 映像ハードミュートの同時呼び出しを直列化するための Actor です
  // MediaChannel 間の排他実行を保証するため static にしています
  static let videoHardMuteActor = VideoHardMuteActor()

  /// この MediaChannel が所有する映像ハードミュート状態を識別します。
  private let videoHardMuteLease: VideoHardMuteLease

  /// カメラと画面共有の開始予約を接続単位で排他する状態です。
  private let videoSourceCoordinator: VideoSourceCoordinator

  /// カメラ状態の確認を process-wide のカメラ操作と直列化します。
  private let cameraCaptureCoordinator: CameraVideoCaptureCoordinator

  // ReplayKit を利用した画面キャプチャ制御です
  // インスタンスが必要な場合は getOrCreateScreenCaptureController 経由で取得します
  // 生成後は MediaChannel のライフサイクルで保持します。
  // stopScreenCapture / internalDisconnect から非同期停止を呼ぶため、
  // 参照を途中で解放せずに同一インスタンスへ停止要求を集約します。
  private var screenCaptureController: ScreenCaptureController?
  // screenCaptureController の生成・参照取得を排他し、
  // startScreenCapture の並行呼び出し時でも単一インスタンスを保証するためのロックです。
  private let screenCaptureControllerLock = NSLock()

  // MARK: - インスタンスの生成

  /// 初期化します。
  ///
  /// - parameter configuration: クライアントの設定
  init(
    configuration: Configuration,
    audioSessionCoordinator: AudioSessionCoordinator = .shared,
    videoHardMuteLease: VideoHardMuteLease = VideoHardMuteLease(),
    cameraCaptureCoordinator: CameraVideoCaptureCoordinator = .shared,
    cameraCaptureOwnership: CameraCaptureOwnership = CameraCaptureOwnership(),
    videoSourceCoordinator: VideoSourceCoordinator = VideoSourceCoordinator()
  ) throws {
    try Self.validate(configuration: configuration)

    let audioSessionUsage: AudioSessionUsage =
      if configuration.audioDevice != nil {
        .custom
      } else if !configuration.audioEnabled {
        .none
      } else if configuration.audioStereoOutputEnabled {
        .stereoRemoteIO
      } else {
        .voiceProcessing(requiresPlayAndRecord: configuration.isSender)
      }

    self.configuration = configuration
    self.videoHardMuteLease = videoHardMuteLease
    self.videoSourceCoordinator = videoSourceCoordinator
    self.cameraCaptureCoordinator = cameraCaptureCoordinator
    self.nativePeerChannelFactory = try NativePeerChannelFactory(
      bypassVoiceProcessing: configuration.bypassVoiceProcessing,
      audioDevice: configuration.audioDevice,
      audioSessionUsage: audioSessionUsage,
      audioSessionCoordinator: audioSessionCoordinator)
    signalingChannel = SignalingChannel.init(configuration: configuration)
    _peerChannel = PeerChannel.init(
      configuration: configuration,
      signalingChannel: signalingChannel,
      nativePeerChannelFactory: nativePeerChannelFactory,
      mediaChannel: self,
      cameraCaptureCoordinator: cameraCaptureCoordinator,
      cameraCaptureOwnership: cameraCaptureOwnership,
      videoSourceCoordinator: videoSourceCoordinator)
    handlers = configuration.mediaChannelHandlers

    _connectionTimer = ConnectionTimer(
      monitors: [
        .signalingChannel(signalingChannel),
        // 同一 init 内で初期化済みのため安全
        // swiftlint:disable:next force_unwrapping
        .peerChannel(_peerChannel!),
      ],
      timeout: configuration.connectionTimeout)
  }

  deinit {
    videoSourceCoordinator.revoke()
    // 明示切断を経由せずに最終参照が解放された場合も、通常切断と同じ所有リソースを破棄する。
    // 各処理は冪等なため、通常切断後の deinit から重複して呼ばれても安全である。
    prepareForDisconnect(error: nil)

    // Sora と利用者の双方が参照を解放した場合も、接続中の PeerChannel を明示的に閉じる。
    // 実処理が進行中なら PeerChannel.Lock が安全な時点まで切断を遅延する。
    _peerChannel?.disconnect(error: nil, reason: .user)
  }

  /// ADM を生成する前に、ステレオ音声出力の組み合わせ制約を検証します。
  static func validate(configuration: Configuration) throws {
    guard configuration.audioStereoOutputEnabled else {
      return
    }
    guard configuration.audioEnabled else {
      throw SoraError.configurationError(
        reason: "audioStereoOutputEnabled requires audioEnabled to be true")
    }
    guard configuration.audioCodec != .pcmu else {
      throw SoraError.configurationError(
        reason: "audioStereoOutputEnabled does not support PCMU")
    }
    guard configuration.audioDevice == nil else {
      throw SoraError.configurationError(
        reason: "audioStereoOutputEnabled cannot be used with a custom audio device")
    }
    guard !configuration.isSender || configuration.initialMicrophoneEnabled else {
      throw SoraError.configurationError(
        reason:
          "audioStereoOutputEnabled requires initialMicrophoneEnabled to be true for sender roles"
      )
    }
  }

  // MARK: - RPC

  /// RPC メソッドを型安全に呼び出します
  ///
  /// このメソッドを使用して、Sora サーバーで定義された RPC メソッドを非同期で実行できます。
  /// - Parameters:
  ///   - method: 呼び出す RPC メソッドの型 (例: `RequestSimulcastRid.self`)
  ///   - params: メソッドに渡すパラメータ。型安全に検証されます
  ///   - isNotificationRequest: `true` の場合、送信後に Sora からのレスポンスを待ちません。デフォルトは `false`
  ///   - timeout: レスポンスを待つ最大時間（秒）。デフォルトは 5.0 秒
  ///
  /// - Returns: メソッドの実行結果。isNotificationRequest が true の場合は nil を返します
  ///
  /// - Throws: 以下のエラーが発生することがあります
  ///   - `SoraError.rpcUnavailable`: RPC チャネルが利用不可
  ///   - `SoraError.rpcEncodingError`: パラメータのエンコーディングに失敗した
  ///   - `SoraError.rpcDecodingError`: レスポンスのデコーディングに失敗した
  ///   - `SoraError.rpcDataChannelClosed`: RPC の送受信に利用する DataChannel が切断された
  ///   - `SoraError.rpcTimeout`: レスポンスがタイムアウト時間内に返されなかった
  ///   - `SoraError.rpcServerError`: Sora からエラーレスポンスがあった
  ///
  /// # 使用例
  /// ```swift
  /// do {
  ///   let response = try await mediaChannel.rpc(
  ///     method: RequestSimulcastRid.self,
  ///     params: RequestSimulcastRidParams(rid: "r0")
  ///   )
  ///
  ///   if let result = response?.result {
  ///     print("Channel ID: \(result.channelId)")
  ///   }
  /// } catch {
  ///   print("RPC call failed: \(error)")
  /// }
  /// ```
  public func rpc<M: RPCMethodProtocol>(
    method: M.Type,
    params: M.Params,
    isNotificationRequest: Bool = false,
    timeout: TimeInterval = 5.0
  ) async throws -> RPCResponse<M.Result>? {
    // タスクキャンセル時に rpcChannel へ通知するための RPC ID を保持する。
    // (withTaskCancellationHandler の onCancel は別スレッドから呼ばれるため、
    // ロックで保護して共有する)
    let cancelledRPCID = CancelledRPCIDStore()
    let rpcChannel = self.peerChannel.rpcChannel
    let response = try await withTaskCancellationHandler(
      operation: {
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<RPCRawResponse?, Error>) in
          guard let rpcChannel else {
            continuation.resume(
              throwing: SoraError.rpcUnavailable(reason: "rpc channel is not available"))
            return
          }
          let id = rpcChannel.call(
            methodName: method.name,
            params: params,
            isNotificationRequest: isNotificationRequest,
            timeout: timeout
          ) { result in
            switch result {
            case .success(let response):
              continuation.resume(returning: response)
            case .failure(let error):
              continuation.resume(throwing: error)
            }
          }
          // call が失敗 (nil を返す) した場合は完了済みのため何もしない
          guard let id else {
            return
          }
          // キャンセル済みのタスクによって登録された RPC は即時にキャンセルする。
          // (onCancel が id の確定前に実行された場合も、ここで検出できる)
          cancelledRPCID.set(id)
          if Task.isCancelled {
            rpcChannel.cancel(identifier: id)
          }
        }
      },
      onCancel: {
        // キャンセルされた場合は、対応する RPC をキャンセルして pending を終端する
        // (RPCChannel が解放済みの場合は invalidate() で全 pending が終端済み)
        if let id = cancelledRPCID.get() {
          rpcChannel?.cancel(identifier: id)
        }
      })
    guard let response else {
      return nil
    }
    return try decodeRPCResponse(response, method: method)
  }

  private func decodeRPCResponse<M: RPCMethodProtocol>(
    _ response: RPCRawResponse,
    method: M.Type
  ) throws -> RPCResponse<M.Result> {
    let decoded: M.Result
    do {
      decoded = try decodeRPCResult(response.result, as: M.Result.self)
    } catch {
      throw SoraError.rpcDecodingError(reason: error.localizedDescription)
    }
    return RPCResponse<M.Result>(id: response.id, result: decoded)
  }

  private func decodeRPCResult<T: Decodable>(_ result: Any, as type: T.Type) throws -> T {
    let data = try JSONSerialization.data(
      withJSONObject: result,
      options: [.fragmentsAllowed])
    let decoder = JSONDecoder()
    return try decoder.decode(T.self, from: data)
  }

  // MARK: - 接続

  private var _handler: ((_ error: Error?) -> Void)?

  /// サーバーに接続します。
  ///
  /// - parameter webRTCConfiguration: WebRTC の設定
  /// - parameter timeout: タイムアウトまでの秒数
  /// - parameter handler: 接続試行後に呼ばれるクロージャー
  /// - parameter error: (接続失敗時) エラー
  func connect(
    webRTCConfiguration: WebRTCConfiguration,
    timeout: Int = 30,
    onPrepared: (() -> Void)? = nil,
    handler: @escaping (_ error: Error?) -> Void
  ) -> ConnectionTask {
    let task = ConnectionTask()
    let peerChannel = self.peerChannel
    connectionLifecycleLock.lock()
    guard state == .disconnected, !hasStartedConnection else {
      connectionLifecycleLock.unlock()
      handler(
        SoraError.connectionBusy(
          reason:
            "MediaChannel is already connected"))
      task.complete()
      return task
    }

    // 非同期処理を開始する前に接続試行を予約する。これにより、連続した connect と
    // 戻り値に対する即時 cancel のどちらも一意な接続試行へ結び付く。
    _handler = handler
    currentConnectionTask = task
    hasStartedConnection = true
    connectionTimerAuthorization.authorizeConnection()
    disconnectStartedWhileConnecting = false
    disconnectPreparation = MediaChannelDisconnectPreparation()
    disconnectFinished = false

    // ConnectionTask を返す前に切断完了ハンドラーを登録する。戻り値に対する即時 cancel や
    // MediaChannel.disconnect が、非同期 basicConnect の開始前に完了しても通知を失わない。
    signalingChannel.internalHandlers.onDisconnect = {
      [weak self, weak peerChannel] error, reason in
      if let self {
        self.beginDisconnect(error: error, reason: reason)
      } else {
        peerChannel?.disconnect(error: error, reason: reason)
      }
    }
    peerChannel.internalHandlers.onDisconnect = { [weak self] error, reason in
      // MediaChannel が先に解放されても ConnectionTask は必ず終端させる。
      guard let self else {
        task.complete()
        return
      }
      self.finishDisconnect(connectionTask: task, error: error, reason: reason)
    }

    // `.connecting` を公開する前に切断完了ハンドラーを登録する。
    // これにより、別スレッドの disconnect が通知登録の隙間へ入ることを防ぐ。
    state = .connecting
    connectionStartTime = nil
    connectionLifecycleLock.unlock()

    // 接続開始を予約して `.connecting` を公開した後に、Sora の管理対象へ登録する。
    // onAddMediaChannel から同期的に disconnect されても、後続の basicConnect は
    // 接続試行が終端済みであることを確認してシグナリングを開始しない。
    onPrepared?()

    DispatchQueue.global().async { [weak self] in
      self?.basicConnect(
        connectionTask: task,
        webRTCConfiguration: webRTCConfiguration,
        timeout: timeout)
    }
    return task
  }

  private func basicConnect(
    connectionTask: ConnectionTask,
    webRTCConfiguration: WebRTCConfiguration,
    timeout: Int
  ) {
    Logger.debug(type: .mediaChannel, message: "try connecting")

    let peerChannel = self.peerChannel

    // 接続開始前にキャンセル要求を受領していた場合は、接続処理を開始しない。
    // attach は peerChannel の設定とキャンセル要求の確認を同じ排他領域で行う。
    guard connectionTask.attach(peerChannel: peerChannel) else {
      Logger.debug(type: .mediaChannel, message: "connection task cancelled before connect")
      connectionTask.markCanceled()
      // 通常の接続失敗と同じく切断フローで後始末する。
      // これにより接続エラー通知と mediaChannel の
      // remove (Sora.connect が設定した internalHandlers.onDisconnectLegacy) が行われる
      beginDisconnect(error: SoraError.connectionCancelled, reason: .user)
      return
    }

    peerChannel.internalHandlers.onAddStream = { [weak self] stream in
      guard let weakSelf = self else {
        return
      }
      Logger.debug(type: .mediaChannel, message: "added a stream")
      Logger.debug(type: .mediaChannel, message: "call onAddStream")
      weakSelf.internalHandlers.onAddStream?(stream)
      weakSelf.handlers.onAddStream?(stream)
    }

    peerChannel.internalHandlers.onRemoveStream = { [weak self] stream in
      guard let weakSelf = self else {
        return
      }
      Logger.debug(type: .mediaChannel, message: "removed a stream")
      Logger.debug(type: .mediaChannel, message: "call onRemoveStream")
      weakSelf.internalHandlers.onRemoveStream?(stream)
      weakSelf.handlers.onRemoveStream?(stream)
    }

    peerChannel.internalHandlers.onOpenDataChannel = { [weak self] label in
      guard let weakSelf = self else {
        return
      }

      // 状態の更新と発火判定はロックで排他し、ハンドラ呼び出しはロックの外で行う
      // (ユーザーコードがロックを保持したまま実行されないようにする)。
      weakSelf.dataChannelOpenLock.lock()
      // onDataChannelOpened はラベルごとに 1 回だけ発火する
      let isFirstOpen = weakSelf.openedDataChannelLabels.insert(label).inserted
      var shouldNotifyBatch = false
      // メッセージング用ラベル（# 始まり）の DataChannel がすべて OPEN になった時点で
      // onDataChannel を一括通知する
      if label.hasPrefix("#") {
        shouldNotifyBatch = weakSelf.shouldNotifyDataChannelAvailableLocked()
      }
      weakSelf.dataChannelOpenLock.unlock()

      if isFirstOpen {
        Logger.debug(type: .mediaChannel, message: "call onDataChannelOpened")
        weakSelf.handlers.onDataChannelOpened?(weakSelf, label)
      }
      if shouldNotifyBatch {
        Logger.debug(type: .mediaChannel, message: "call onDataChannel")
        weakSelf.handlers.onDataChannel?(weakSelf)
      }
    }

    peerChannel.internalHandlers.onReceiveSignalingJSON = { [weak self] json in
      guard let weakSelf = self else {
        return
      }
      Logger.debug(type: .mediaChannel, message: "receive signaling json")
      Logger.debug(type: .mediaChannel, message: "call onReceiveSignalingJSON")
      weakSelf.internalHandlers.onReceiveSignalingJSON?(json)
      weakSelf.handlers.onReceiveSignalingJSON?(json)
    }

    peerChannel.internalHandlers.onReceiveSignaling = { [weak self] message in
      guard let weakSelf = self else {
        return
      }
      Logger.debug(type: .mediaChannel, message: "receive signaling")
      switch message {
      case .notify(let message):
        // connectionCount, channelRecvonlyConnections, channelSendonlyConnections, channelSendrecvConnections
        // 全てに値が入っていた時のみプロパティを更新する
        if let connectionCount = message.connectionCount,
          let sendonlyConnections = message.channelSendonlyConnections,
          let recvonlyConnections = message.channelRecvonlyConnections,
          let sendrecvConnections = message.channelSendrecvConnections
        {
          weakSelf.publisherCount = sendonlyConnections + sendrecvConnections
          weakSelf.subscriberCount = recvonlyConnections + sendrecvConnections
          weakSelf.connectionCount = connectionCount
        } else {
        }
      default:
        break
      }

      Logger.debug(type: .mediaChannel, message: "call onReceiveSignaling")
      weakSelf.internalHandlers.onReceiveSignaling?(message)
      weakSelf.handlers.onReceiveSignaling?(message)
    }

    // タイマーの開始と接続試行の有効性確認を、切断状態の遷移と同じロックで直列化する。
    // これにより、切断完了後に遅れてタイマーを再始動する競合を防ぐ。
    connectionLifecycleLock.lock()
    guard state == .connecting, currentConnectionTask === connectionTask,
      connectionTask.state == .connecting,
      connectionTimerAuthorization.beginTimer()
    else {
      connectionLifecycleLock.unlock()
      Logger.debug(type: .mediaChannel, message: "connection task cancelled before connect")
      if connectionTask.state == .canceled {
        connectionTask.markCanceled()
        beginDisconnect(error: SoraError.connectionCancelled, reason: .user)
      }
      return
    }

    connectionStartTime = Date()
    connectionTimer.run {
      Logger.error(type: .mediaChannel, message: "connection timeout")
      self.beginDisconnect(error: SoraError.connectionTimeout, reason: .signalingFailure)
    }
    connectionLifecycleLock.unlock()

    peerChannel.connect { [weak self] error in
      guard let self else {
        return
      }

      // 成否にかかわらず PeerChannel の終端通知を受けた時点でタイマーを止める。
      self.connectionTimer.stop()
      if let error {
        Logger.error(type: .mediaChannel, message: "failed to connect")
        self.beginDisconnect(error: error, reason: .signalingFailure)
        return
      }

      self.finishConnect(connectionTask: connectionTask)
    }
  }

  /// PeerChannel の接続成功を、cancel や切断開始と競合しないよう確定します。
  private func finishConnect(connectionTask: ConnectionTask) {
    var connectHandler: ((Error?) -> Void)?
    var shouldCancel = false

    connectionLifecycleLock.lock()
    if state == .connecting, currentConnectionTask === connectionTask {
      if connectionTask.tryComplete() {
        connectionTimerAuthorization.terminate()
        state = .connected
        connectHandler = _handler
        _handler = nil
        currentConnectionTask = nil
      } else {
        // ConnectionTask.cancel() が先に終端状態を確定している。
        shouldCancel = true
      }
    }
    connectionLifecycleLock.unlock()

    connectionTimer.stop()

    if shouldCancel {
      connectionTask.markCanceled()
      beginDisconnect(error: SoraError.connectionCancelled, reason: .user)
      return
    }
    guard let connectHandler else {
      return
    }

    Logger.debug(type: .mediaChannel, message: "did connect")
    connectHandler(nil)
    Logger.debug(type: .mediaChannel, message: "call onConnect")
    internalHandlers.onConnect?(nil)
    handlers.onConnect?(nil)
  }

  /// 接続を解除します。
  ///
  /// - parameter error: 接続解除の原因となったエラー
  public func disconnect(error: Error?) {
    // reason に .user を指定しているので、 disconnect は SDK 内部では利用しない
    beginDisconnect(error: error, reason: .user)
  }

  func internalDisconnect(error: Error?, reason: DisconnectReason) {
    beginDisconnect(error: error, reason: reason)
  }

  /// 切断開始を 1 回だけ確定し、PeerChannel へ切断を要求します。
  ///
  /// 公開ハンドラーと `.disconnected` への遷移は、PeerChannel が native close と
  /// AudioSession lease の解放を終えた後の `finishDisconnect` で実行します。
  private func beginDisconnect(error: Error?, reason: DisconnectReason) {
    var shouldPrepare = false

    connectionLifecycleLock.lock()
    switch state {
    case .connecting, .connected:
      disconnectStartedWhileConnecting = state == .connecting
      connectionTimerAuthorization.terminate()
      if disconnectStartedWhileConnecting {
        // 接続試行をここで seal し、遅延切断中の cancel が切断理由を上書きしないようにする。
        currentConnectionTask?.complete()
      }
      state = .disconnecting
      if disconnectPreparation.begin() {
        shouldPrepare = true
      }
    case .disconnecting, .disconnected:
      break
    }
    connectionLifecycleLock.unlock()

    guard shouldPrepare else {
      return
    }

    startDisconnectPreparation(error: error)
    peerChannel.disconnect(error: error, reason: reason)
  }

  /// PeerChannel の実切断完了後に状態と公開ハンドラーを 1 回だけ終端します。
  private func finishDisconnect(
    connectionTask: ConnectionTask,
    error: Error?,
    reason: DisconnectReason
  ) {
    var shouldPrepare = false
    var shouldNotifyConnect = false
    var connectHandler: ((Error?) -> Void)?

    connectionLifecycleLock.lock()
    guard !disconnectFinished else {
      connectionLifecycleLock.unlock()
      connectionTask.complete()
      return
    }

    // ConnectionTask.cancel() は PeerChannel を直接切断するため、MediaChannel 側で
    // beginDisconnect を経由せずに完了通知へ到達する場合がある。
    if state == .connecting || state == .connected {
      disconnectStartedWhileConnecting = state == .connecting
      connectionTimerAuthorization.terminate()
      state = .disconnecting
    }
    guard state == .disconnecting else {
      connectionLifecycleLock.unlock()
      connectionTask.complete()
      return
    }

    let completion = MediaChannelDisconnectPreparation.Completion(
      connectionTask: connectionTask,
      error: error,
      reason: reason)
    switch disconnectPreparation.receive(completion) {
    case .prepare:
      shouldPrepare = true
    case .deferred:
      // PeerChannel の cleanup は完了済みでも、MediaChannel 固有の準備が終わるまでは
      // `.disconnected` と公開 callback を通知しない。
      connectionLifecycleLock.unlock()
      return
    case .ready:
      break
    }

    if shouldPrepare {
      connectionLifecycleLock.unlock()
      startDisconnectPreparation(error: error)
      return
    }

    disconnectFinished = true
    shouldNotifyConnect = disconnectStartedWhileConnecting
    if shouldNotifyConnect {
      connectHandler = _handler
    }
    _handler = nil
    currentConnectionTask = nil
    state = .disconnected
    connectionLifecycleLock.unlock()

    // 利用者ハンドラーから観測した時点で ConnectionTask が必ず終端しているようにする。
    connectionTask.complete()

    if shouldNotifyConnect {
      connectHandler?(error)
      Logger.debug(type: .mediaChannel, message: "call onConnect")
      internalHandlers.onConnect?(error)
      handlers.onConnect?(error)
    }

    Logger.debug(type: .mediaChannel, message: "did disconnect")
    Logger.debug(type: .mediaChannel, message: "call onDisconnect")
    internalHandlers.onDisconnectLegacy?(error)
    handlers.onDisconnectLegacy?(error)
    handlers.onDisconnect?(makeDisconnectEvent(error: error))
  }

  /// 切断準備を完了状態へ進め、準備中に保留された PeerChannel の完了通知を処理します。
  private func completeDisconnectPreparation() {
    let completion: MediaChannelDisconnectPreparation.Completion?

    connectionLifecycleLock.lock()
    completion = disconnectPreparation.complete()
    connectionLifecycleLock.unlock()

    if let completion {
      finishDisconnect(
        connectionTask: completion.connectionTask,
        error: completion.error,
        reason: completion.reason)
    }
  }

  /// MediaChannel 固有の cleanup が完了した後に、切断準備を完了状態へ進めます。
  private func startDisconnectPreparation(error: Error?) {
    let cleanupTask = prepareForDisconnect(error: error)
    let weakSelf = WeakMediaChannelBox(self)
    Task { @Sendable in
      await cleanupTask.value
      weakSelf.value?.completeDisconnectPreparation()
    }
  }

  /// MediaChannel が所有するタイマー、画面キャプチャ、ハードミュート状態を停止します。
  /// 戻り値の Task は、画面共有停止と映像ハードミュート lease の破棄完了を表します。
  @discardableResult
  private func prepareForDisconnect(error: Error?) -> Task<Void, Never> {
    // 進行中のハードミュート解除がカメラ開始後に必ず取消を検知できるよう、
    // Actor の cleanup Task を生成する前に lease を同期的に無効化する。
    videoHardMuteLease.revoke()
    // 非同期のカメラ / 画面共有開始が遅れて完了しても、新しい送信元として確定させない。
    videoSourceCoordinator.revoke()

    // 接続の終了時に画面キャプチャを停止します。
    // 論理停止は同期的に確定し、ReplayKit の停止完了を公開 callback より前に待ちます。
    // スクリーンキャプチャ未使用時はインスタンス未生成のため何もしません。
    let screenCaptureController = currentScreenCaptureController()
    let screenCaptureStopTask = screenCaptureController?.stopCaptureForDisconnect()
    let videoSourceCoordinator = videoSourceCoordinator

    // 接続切断時に、この接続が保存したハードミュートの capturer を破棄します。
    // (別接続がこの接続の capturer を取得しないようにするため)
    let hardMuteLease = videoHardMuteLease
    let hardMuteCleanupTask = Task { @Sendable in
      await Self.videoHardMuteActor.release(lease: hardMuteLease)
    }
    let cleanupTask = Task { @Sendable in
      await screenCaptureStopTask?.value
      videoSourceCoordinator.finishScreenStop(
        stopped: screenCaptureController?.isCaptureActive() != true)
      await hardMuteCleanupTask.value
    }

    Logger.debug(type: .mediaChannel, message: "try disconnecting")
    if let error {
      Logger.error(
        type: .mediaChannel,
        message: "error: \(error.localizedDescription)")
    }
    connectionTimer.stop()
    return cleanupTask
  }

  /// 切断エラーを公開 SoraCloseEvent へ変換します。
  private func makeDisconnectEvent(error: Error?) -> SoraCloseEvent {
    guard let error else {
      return SoraCloseEvent.ok(code: 1000, reason: "NO-ERROR")
    }
    if let soraError = error as? SoraError {
      switch soraError {
      case .webSocketClosed(let code, let reason):
        // 基本的に reason が nil になるケースはないが、nil の場合は空文字列とする。
        return SoraCloseEvent.ok(code: code.intValue(), reason: reason ?? "")
      case .dataChannelClosed(let code, let reason):
        return SoraCloseEvent.ok(code: code, reason: reason)
      default:
        return SoraCloseEvent.error(error)
      }
    }
    return SoraCloseEvent.error(error)
  }

  /// libwebrtc の統計情報を取得します。
  /// 非同期取得中に切断された場合でも安全になるよう、コールバック内で
  /// self の生存確認、state == .connected の再確認、peerChannel.nativeChannel が同一インスタンスかどうか、をチェックしています。
  ///
  /// - parameter handler: 統計情報取得後に呼ばれるクロージャー
  public func getStats(handler: @escaping (Result<Statistics, Error>) -> Void) {
    guard state == .connected else {
      let message = "MediaChannel is not connected (state: \(state))"
      Logger.debug(type: .mediaChannel, message: message)
      handler(.failure(SoraError.peerChannelError(reason: message)))
      return
    }

    guard let peerConnection = peerChannel.nativeChannel else {
      let message =
        "RTCPeerConnection is unavailable (state: \(state), nativeChannel: nil)"
      Logger.debug(type: .mediaChannel, message: message)
      handler(.failure(SoraError.peerChannelError(reason: message)))
      return
    }

    // peerConnection.statistics クロージャはlibwebrtc 側のスレッドから遅れて呼ばれ、内部で MediaChannel をキャプチャします。
    // ここで self を強参照すると、MediaChannel が切断・解放されたあとでもクロージャが解放されず、deinit が遅れたり循環参照が発生する恐れがあります。
    // そのため [weak self] でキャプチャし、呼び出し時点で MediaChannel がまだ有効かどうかをチェックしています。
    // self が解放済みなら MediaChannel is unavailable エラーを返すことで安全に処理を抜けます。
    peerConnection.statistics { [weak self] report in
      guard let self else {
        handler(.failure(SoraError.peerChannelError(reason: "MediaChannel is unavailable")))
        return
      }

      guard self.state == .connected else {
        let message = "MediaChannel is not connected (state: \(self.state))"
        Logger.debug(type: .mediaChannel, message: message)
        handler(.failure(SoraError.peerChannelError(reason: message)))
        return
      }

      guard let currentPeerConnection = self.peerChannel.nativeChannel,
        currentPeerConnection === peerConnection
      else {
        let message =
          "RTCPeerConnection is unavailable (state: \(self.state), nativeChannel changed)"
        Logger.debug(type: .mediaChannel, message: message)
        handler(.failure(SoraError.peerChannelError(reason: message)))
        return
      }

      handler(.success(Statistics(contentsOf: report)))
    }
  }

  /// DataChannel を利用してメッセージを送信します
  public func sendMessage(label: String, data: Data) -> Error? {
    guard peerChannel.switchedToDataChannel else {
      // redirect 中は旧 DataChannel への送信を防ぐため false にしている。
      // 利用者には「まだ指定した DataChannel に接続されていない」として通知する。
      if peerChannel.isRedirecting {
        Logger.debug(
          type: .mediaChannel,
          message: "sendMessage: rejected (redirecting): label => \(label)")
      }
      return SoraError.messagingError(reason: "DataChannel is not open yet")
    }

    guard label.starts(with: "#") else {
      return SoraError.messagingError(reason: "label should start with #")
    }

    guard let dc = peerChannel.dataChannels[label] else {
      return SoraError.messagingError(reason: "no DataChannel found: label => \(label)")
    }

    let readyState = dc.readyState
    guard readyState == .open else {
      return SoraError.messagingError(
        reason:
          "readyState of the DataChannel is not open: label => \(label), readyState => \(readyState)"
      )
    }

    let result = dc.send(data)

    return result
      ? nil : SoraError.messagingError(reason: "failed to send message: label => \(label)")
  }

  /// メッセージング用ラベル（offer の `data_channels` から抽出した `#` 始まりのラベル）が
  /// すべてクライアント側で OPEN になった場合に `onDataChannel` を発火すべきかを判定します。
  /// 状態を持たない純粋関数であり、単体テストの対象です。
  ///
  /// - Parameters:
  ///   - messagingLabels: offer の `data_channels` から抽出した `#` 始まりのラベル集合
  ///   - openedLabels: クライアント側で OPEN になった DataChannel のラベル集合
  ///     (メッセージング用ラベルは必ず含まれる)
  ///   - notified: 一括通知済みかどうか (`true` の場合は二重発火を防ぐため発火しない)
  /// - Returns: `onDataChannel` を発火すべきか
  static func shouldNotifyDataChannelAvailable(
    messagingLabels: Set<String>,
    openedLabels: Set<String>,
    notified: Bool
  ) -> Bool {
    // 一括通知済みの場合は発火しない (二重発火の防止)
    guard !notified else {
      return false
    }

    // メッセージング用ラベルが存在しない場合は発火しない
    guard !messagingLabels.isEmpty else {
      return false
    }

    // すべてのメッセージング用ラベルが OPEN になった場合のみ発火する
    guard messagingLabels.isSubset(of: openedLabels) else {
      return false
    }

    return true
  }

  /// offer の `data_channels` からメッセージング用ラベル（`#` 始まり）の集合を抽出します。
  /// 状態を持たない純粋関数であり、単体テストの対象です。
  ///
  /// - Parameter dataChannels: offer の `data_channels` の値
  /// - Returns: メッセージング用ラベルの集合 (`label` キーが欠落・非 String の要素は無視)
  static func messagingLabels(from dataChannels: [[String: Any]]) -> Set<String> {
    Set(
      dataChannels.compactMap { $0["label"] as? String }.filter {
        $0.hasPrefix("#")
      })
  }

  /// メッセージング用ラベルがすべてクライアント側で OPEN になった場合に true を返し、
  /// 一括通知済みフラグを立てます。呼び出し元は `dataChannelOpenLock` を保持していること。
  private func shouldNotifyDataChannelAvailableLocked() -> Bool {
    let shouldNotify = Self.shouldNotifyDataChannelAvailable(
      messagingLabels: messagingLabels,
      openedLabels: openedDataChannelLabels,
      notified: onDataChannelNotified)
    if shouldNotify {
      onDataChannelNotified = true
    }
    return shouldNotify
  }

  /// DataChannel の OPEN 追跡状態と一括通知フラグをリセットします。
  /// リダイレクト等で offer が再送された場合に PeerChannel から呼ばれます。
  ///
  /// - Parameter messagingLabels: 新しい offer の `data_channels` から抽出した
  ///   メッセージング用ラベルの集合
  func resetDataChannelNotificationState(messagingLabels: Set<String>) {
    dataChannelOpenLock.lock()
    self.messagingLabels = messagingLabels
    openedDataChannelLabels = []
    onDataChannelNotified = false
    dataChannelOpenLock.unlock()
  }

  /// MediaChannel の接続中にマイクをハードミュート有効化/無効化します
  ///
  /// - Parameter mute: `true` で有効化、`false` で無効化
  /// - Returns: 成功した場合は `nil`、失敗した場合は `SoraError.mediaChannelError` を返します
  public func setAudioHardMute(_ mute: Bool) -> Error? {
    // ステレオ再生では Voice Processing の録音ポーズ/再開 API を利用できない。
    guard !configuration.audioStereoOutputEnabled else {
      return SoraError.mediaChannelError(
        reason: "setAudioHardMute is not supported when stereo playout is enabled")
    }

    // 接続されていなければエラー
    guard state == .connected else {
      return SoraError.mediaChannelError(
        reason: "MediaChannel is not connected (state: \(state))")
    }

    // 接続設定で音声が有効になっていなければエラー
    guard configuration.audioEnabled else {
      return SoraError.mediaChannelError(reason: "audioEnabled is false")
    }

    // 接続設定で配信側ロールになっていなければエラー
    guard configuration.isSender else {
      return SoraError.mediaChannelError(reason: "role is not sender")
    }

    // 通常経路: RTCAudioDeviceModule のラッパーでハードミュートを切り替える
    if let wrapper = self.nativePeerChannelFactory.audioDeviceModuleWrapper {
      if !wrapper.setAudioHardMute(mute) {
        return SoraError.mediaChannelError(
          reason: "AudioDeviceModuleWrapper::setAudioHardMute failed")
      }
      return nil
    }

    // ダミー音声経路: DummyAudioDevice でハードミュートを切り替える
    if let dummyDevice = self.nativePeerChannelFactory.audioDevice as? DummyAudioDevice {
      if !dummyDevice.setHardMute(mute) {
        return SoraError.mediaChannelError(
          reason: "DummyAudioDevice::setHardMute failed")
      }
      return nil
    }

    return SoraError.mediaChannelError(
      reason: "setAudioHardMute is not supported")
  }

  /// MediaChannel の接続中にマイクをソフトミュート有効化 / 無効化します
  ///
  /// - Parameter mute: `true` で有効化、`false` で無効化
  /// - Returns: 成功した場合は `nil`、失敗した場合は `SoraError.mediaChannelError` を返します
  public func setAudioSoftMute(_ mute: Bool) -> Error? {
    // 接続されていなければエラー
    guard state == .connected else {
      return SoraError.mediaChannelError(
        reason: "MediaChannel is not connected (state: \(state))")
    }

    // 接続設定で音声が有効になっていなければエラー
    guard configuration.audioEnabled else {
      return SoraError.mediaChannelError(reason: "audioEnabled is false")
    }

    // 接続設定で配信側ロールになっていなければエラー
    guard configuration.isSender else {
      return SoraError.mediaChannelError(reason: "role is not sender")
    }

    // 送信ストリームが有効でなければエラー
    guard let senderStream else {
      return SoraError.mediaChannelError(reason: "senderStream is unavailable")
    }

    // ローカル音声トラックが存在しなければエラー
    guard senderStream.hasAudioTrack else {
      return SoraError.mediaChannelError(reason: "senderStream has no AudioTrack")
    }

    // ローカル音声トラックの有効/無効を切り替えます
    senderStream.audioEnabled = !mute
    Logger.debug(type: .mediaChannel, message: "setAudioSoftMute mute=\(mute)")
    return nil
  }

  /// MediaChannel の接続中に映像をソフトミュート有効化 / 無効化します
  /// 黒塗りフレームが送信される状態になります
  ///
  /// - Parameter mute: `true` で有効化、`false` で無効化
  /// - Returns: 成功した場合は `nil`、失敗した場合は `SoraError.mediaChannelError` を返します
  public func setVideoSoftMute(_ mute: Bool) -> Error? {
    let senderStream: MediaStream
    switch requireSenderStreamForVideoMute() {
    case .failure(let error):
      return error
    case .success(let stream):
      senderStream = stream
    }

    // ローカル映像トラックの有効/無効を切り替えます
    senderStream.videoEnabled = !mute
    Logger.debug(type: .mediaChannel, message: "setVideoSoftMute mute=\(mute)")
    return nil
  }

  /// MediaChannel の接続中に映像をハードミュート有効化 / 無効化します
  ///
  /// 端末カメラ利用が有効になっている必要があります
  /// 外部入力や別キャプチャ経路には対応していません
  ///
  /// 内部で Actor により、操作を排他実行します。
  /// 同時に呼び出された場合は Actor 側で `SoraError.mediaChannelError` がスローされます
  ///
  /// 映像ハードミュートは、黒塗りフレーム状態で停止させるためローカルトラックの停止を含みます
  /// 事前に映像ソフトミュートを利用していた場合は状態が上書きされます
  /// ハードミュート解除時に直前のソフトミュートの状態を復元するようなことはしません
  ///
  /// - Parameter mute: `true` で有効化、`false` で無効化
  /// - Throws: エラー時は `SoraError.cameraError` または `SoraError.mediaChannelError` がスローされます
  public func setVideoHardMute(_ mute: Bool) async throws {
    let senderStream: MediaStream
    switch requireSenderStreamForVideoMute() {
    case .failure(let error):
      throw error
    case .success(let stream):
      senderStream = stream
    }

    // 接続設定でカメラ利用が有効になっているか
    // 端末カメラではなく別ソース（外部入力や別キャプチャ経路）の場合は false になることがあり、機能としては未対応
    guard configuration.cameraSettings.isEnabled else {
      throw SoraError.mediaChannelError(reason: "cameraSettings.isEnabled is false")
    }

    if mute {
      // ソフトミュートによる黒塗りフレーム送出 -> ハードミュート有効化の順になるようにします
      senderStream.videoEnabled = false
      try await Self.videoHardMuteActor.setMute(
        mute: true,
        lease: videoHardMuteLease,
        senderStream: SenderStreamBox(stream: senderStream),
        cameraSettings: CameraSettingsSnapshot(configuration.cameraSettings)
      )
      videoSourceCoordinator.releaseCamera()
    } else {
      guard let reservation = videoSourceCoordinator.beginCamera(stream: senderStream) else {
        throw SoraError.mediaChannelError(
          reason:
            "screen capture is active, stopScreenCapture before setVideoHardMute(false)")
      }

      // ハードミュート無効化 -> ソフトミュートによる黒塗りフレーム送出解除の順になるようにします
      do {
        try await Self.videoHardMuteActor.setMute(
          mute: false,
          lease: videoHardMuteLease,
          senderStream: SenderStreamBox(stream: senderStream),
          cameraSettings: CameraSettingsSnapshot(configuration.cameraSettings)
        )
      } catch {
        _ = videoSourceCoordinator.completeCamera(reservation, active: false)
        throw error
      }
      guard videoSourceCoordinator.completeCamera(reservation, active: true) else {
        throw SoraError.mediaChannelError(
          reason: "video hard mute operation was cancelled")
      }
      senderStream.videoEnabled = true
    }
    Logger.debug(type: .mediaChannel, message: "setVideoHardMute mute=\(mute)")
  }

  /// MediaChannel の接続中に ReplayKit を利用して画面キャプチャおよび映像配信を開始します
  ///
  /// 送信フレームレートは `ScreenCaptureSettings.targetFPS` で制御できます。
  ///
  /// 同一 senderStream に対してカメラキャプチャが動作中の場合は開始できません。
  /// 接続前に `Configuration.initialCameraEnabled = false` を設定してください。
  /// 接続後にカメラを停止する場合は `setVideoHardMute(true)` を先に呼んでください。
  ///
  /// - Parameter settings: 画面キャプチャ設定
  /// - Throws: エラー時は `SoraError.mediaChannelError` または ReplayKit 起因のエラーがスローされます
  public func startScreenCapture(settings: ScreenCaptureSettings = .init()) async throws {
    let senderStream: MediaStream
    switch requireSenderStreamForVideoMute() {
    case .failure(let error):
      throw error
    case .success(let stream):
      senderStream = stream
    }

    // controller を最初の await より前に保持し、並行する停止または切断が
    // 遅延中の開始を必ず取り消せるようにする。
    let screenCaptureController = getOrCreateScreenCaptureController()
    guard let reservation = videoSourceCoordinator.beginScreen(stream: senderStream) else {
      throw SoraError.mediaChannelError(
        reason:
          "camera capture is running on senderStream, call setVideoHardMute(true) before startScreenCapture"
      )
    }

    do {
      // 公開 API から直接開始されたカメラも確認し、同じ送信ストリームでの二重送信を防ぐ。
      guard
        !(await isCameraVideoCaptureRunning(
          on: senderStream,
          authorization: reservation))
      else {
        throw SoraError.mediaChannelError(
          reason:
            "camera capture is running on senderStream, call setVideoHardMute(true) before startScreenCapture"
        )
      }

      try await screenCaptureController.startCapture(
        settings: settings,
        senderStream: senderStream,
        authorization: reservation,
        videoSourceCoordinator: videoSourceCoordinator
      )
      guard videoSourceCoordinator.completeScreenStart(reservation) else {
        await screenCaptureController.stopCapture()
        videoSourceCoordinator.finishScreenStop(
          stopped: !screenCaptureController.isCaptureActive())
        throw SoraError.mediaChannelError(reason: "screen capture start was cancelled")
      }
    } catch {
      if screenCaptureController.isCaptureActive() {
        _ = videoSourceCoordinator.beginScreenStop()
        await screenCaptureController.stopCapture()
        videoSourceCoordinator.finishScreenStop(
          stopped: !screenCaptureController.isCaptureActive())
      } else {
        videoSourceCoordinator.failScreenStart(reservation)
      }
      throw error
    }
    Logger.debug(type: .mediaChannel, message: "startScreenCapture")
  }

  /// ReplayKit を利用した画面キャプチャを停止します
  public func stopScreenCapture() async {
    _ = videoSourceCoordinator.beginScreenStop()
    let screenCaptureController = currentScreenCaptureController()
    await screenCaptureController?.stopCapture()
    videoSourceCoordinator.finishScreenStop(
      stopped: screenCaptureController?.isCaptureActive() != true)
    Logger.debug(type: .mediaChannel, message: "stopScreenCapture")
  }

  /// 画面キャプチャが動作中かを取得します
  public func isScreenCaptureActive() -> Bool {
    currentScreenCaptureController()?.isCaptureActive() ?? false
  }

  // screenCaptureController インスタンスを取得します
  // インスタンス未生成の場合は生成します
  // スクリーンキャプチャ機能は必ず利用するとは限らないため必要時に生成しています
  func getOrCreateScreenCaptureController(
    recorderCoordinator: ScreenCaptureRecorderCoordinator = .shared
  ) -> ScreenCaptureController {
    withScreenCaptureControllerLock {
      if let screenCaptureController {
        return screenCaptureController
      }

      let screenCaptureController = ScreenCaptureController(
        mediaChannel: self,
        recorderCoordinator: recorderCoordinator)
      self.screenCaptureController = screenCaptureController
      return screenCaptureController
    }
  }

  // Current の ScreenCaptureController を取得します。
  // キャプチャ終了時、切断時に取得するために利用します。
  private func currentScreenCaptureController() -> ScreenCaptureController? {
    withScreenCaptureControllerLock {
      screenCaptureController
    }
  }

  // ScreenCaptureController をロック付きで取得します
  private func withScreenCaptureControllerLock<T>(_ block: () throws -> T) rethrows -> T {
    screenCaptureControllerLock.lock()
    defer { screenCaptureControllerLock.unlock() }
    return try block()
  }

  // 映像ミュートのための接続状況や接続設定のチェックを実行した上で送信ストリームを取得します
  //
  // チェックを全て通過した場合は .success で送信ストリームを返します
  // 問題があった場合は .failure で SoraError.mediaChannelError を返します
  private func requireSenderStreamForVideoMute() -> Result<MediaStream, Error> {
    // 接続されていなければエラー
    guard state == .connected else {
      return .failure(
        SoraError.mediaChannelError(reason: "MediaChannel is not connected (state: \(state))"))
    }

    // 接続設定で映像が有効になっていなければエラー
    guard configuration.videoEnabled else {
      return .failure(SoraError.mediaChannelError(reason: "videoEnabled is false"))
    }

    // 接続設定で配信側ロールになっていなければエラー
    guard configuration.isSender else {
      return .failure(SoraError.mediaChannelError(reason: "role is not sender"))
    }

    // 送信ストリームが有効になっていなければエラー
    guard let senderStream else {
      return .failure(SoraError.mediaChannelError(reason: "senderStream is unavailable"))
    }

    // 送信ストリームに映像トラックが含まれていなければエラー
    guard senderStream.hasVideoTrack else {
      return .failure(SoraError.mediaChannelError(reason: "senderStream has no VideoTrack"))
    }

    return .success(senderStream)
  }

  // 指定した senderStream に対してカメラキャプチャが実行中かを返します
  private func isCameraVideoCaptureRunning(
    on senderStream: MediaStream,
    authorization: VideoSourceCoordinator.Reservation
  ) async -> Bool {
    let videoSourceCoordinator = videoSourceCoordinator
    let senderStream = SenderStreamBox(stream: senderStream)
    return await cameraCaptureCoordinator.perform {
      guard videoSourceCoordinator.isValid(authorization) else {
        return true
      }
      guard let current = await CameraVideoCapturer.currentForSDK(),
        current.isRunning,
        let currentSenderStream = current.stream
      else {
        return false
      }
      return currentSenderStream === senderStream.stream
    }
  }
}

extension MediaChannel: CustomStringConvertible {
  /// :nodoc:
  public var description: String {
    "MediaChannel(clientId: \(clientId ?? "-"), role: \(configuration.role))"
  }
}

/// :nodoc:
extension MediaChannel: Equatable {
  public static func == (lhs: MediaChannel, rhs: MediaChannel) -> Bool {
    ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
  }
}
