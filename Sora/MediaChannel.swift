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

  // PeerChannel に mediaChannel を保持させる際にこの書き方が必要になった
  private var _connectionTimer: ConnectionTimer?

  private let manager: Sora
  private let nativePeerChannelFactory: NativePeerChannelFactory

  // 映像ハードミュートの同時呼び出しを直列化するための Actor です
  // MediaChannel 間の排他実行を保証するため static にしています
  private static let videoHardMuteActor = VideoHardMuteActor()

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
  /// - parameter manager: `Sora` オブジェクト
  /// - parameter configuration: クライアントの設定
  init(manager: Sora, configuration: Configuration) {
    self.manager = manager
    self.configuration = configuration
    self.nativePeerChannelFactory = NativePeerChannelFactory(
      bypassVoiceProcessing: configuration.bypassVoiceProcessing,
      audioDevice: configuration.audioDevice)
    signalingChannel = SignalingChannel.init(configuration: configuration)
    _peerChannel = PeerChannel.init(
      configuration: configuration,
      signalingChannel: signalingChannel,
      nativePeerChannelFactory: nativePeerChannelFactory,
      mediaChannel: self)
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

  private func executeHandler(error: Error?) {
    _handler?(error)
    _handler = nil
  }

  /// サーバーに接続します。
  ///
  /// - parameter webRTCConfiguration: WebRTC の設定
  /// - parameter timeout: タイムアウトまでの秒数
  /// - parameter handler: 接続試行後に呼ばれるクロージャー
  /// - parameter error: (接続失敗時) エラー
  func connect(
    webRTCConfiguration: WebRTCConfiguration,
    timeout: Int = 30,
    handler: @escaping (_ error: Error?) -> Void
  ) -> ConnectionTask {
    let task = ConnectionTask()
    if state.isConnecting {
      handler(
        SoraError.connectionBusy(
          reason:
            "MediaChannel is already connected"))
      task.complete()
      return task
    }

    DispatchQueue.global().async { [weak self] in
      self?.basicConnect(
        connectionTask: task,
        webRTCConfiguration: webRTCConfiguration,
        timeout: timeout,
        handler: handler)
    }
    return task
  }

  private func basicConnect(
    connectionTask: ConnectionTask,
    webRTCConfiguration: WebRTCConfiguration,
    timeout: Int,
    handler: @escaping (Error?) -> Void
  ) {
    Logger.debug(type: .mediaChannel, message: "try connecting")
    _handler = handler
    state = .connecting
    connectionStartTime = nil

    // 接続開始前にキャンセル要求を受領していた場合は、接続処理を開始しない。
    // attach は peerChannel の設定とキャンセル要求の確認を同じ排他領域で行う。
    guard connectionTask.attach(peerChannel: peerChannel) else {
      Logger.debug(type: .mediaChannel, message: "connection task cancelled before connect")
      connectionTask.markCanceled()
      // 通常の接続失敗と同じく切断フローで後始末する。
      // これにより executeHandler 経由の接続エラー通知と mediaChannel の
      // remove (Sora.connect が設定した internalHandlers.onDisconnectLegacy) が行われる
      internalDisconnect(error: SoraError.connectionCancelled, reason: .user)
      return
    }

    signalingChannel.internalHandlers.onDisconnect = { [weak self] error, reason in
      guard let weakSelf = self else {
        return
      }
      if weakSelf.state == .connecting || weakSelf.state == .connected {
        weakSelf.internalDisconnect(error: error, reason: reason)
      }
      connectionTask.complete()
    }

    peerChannel.internalHandlers.onDisconnect = { [weak self] error, reason in
      guard let weakSelf = self else {
        return
      }
      if weakSelf.state == .connecting || weakSelf.state == .connected {
        weakSelf.internalDisconnect(error: error, reason: reason)
      }
      connectionTask.complete()
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

    // attach 成功後〜ここまでの間に cancel() が割り込んだ場合は、接続を開始しない。
    // (attach の瞬間だけを確認すると、ハンドラ設定などの間に割り込んだ cancel を
    // 検出できず、次の peerChannel.connect で接続が開始されてしまう)
    guard connectionTask.state == .connecting else {
      Logger.debug(type: .mediaChannel, message: "connection task cancelled before connect")
      connectionTask.markCanceled()
      internalDisconnect(error: SoraError.connectionCancelled, reason: .user)
      return
    }

    peerChannel.connect { [weak self] error in
      guard let weakSelf = self else {
        return
      }

      // cancel() が接続成功より先に成立していた場合は、成功通知を発火させない。
      // complete() を先に呼ぶと _state == .completed になり、判定できないため
      // complete() の前に状態を確認する。
      if connectionTask.state != .connecting {
        connectionTask.markCanceled()
        weakSelf.connectionTimer.stop()
        weakSelf.internalDisconnect(error: SoraError.connectionCancelled, reason: .user)
        return
      }

      weakSelf.connectionTimer.stop()
      connectionTask.complete()

      if let error {
        Logger.error(type: .mediaChannel, message: "failed to connect")
        weakSelf.internalDisconnect(error: error, reason: .signalingFailure)
        // internalDisconnect が接続試行中のエラー通知を executeHandler 経由で
        // すでに実行している場合があるため、ここでは executeHandler 経由でのみ
        // 通知する (二重呼び出し防止)
        weakSelf.executeHandler(error: error)

        Logger.debug(type: .mediaChannel, message: "call onConnect")
        weakSelf.internalHandlers.onConnect?(error)
        weakSelf.handlers.onConnect?(error)
        return
      }
      Logger.debug(type: .mediaChannel, message: "did connect")
      weakSelf.state = .connected
      handler(nil)
      Logger.debug(type: .mediaChannel, message: "call onConnect")
      weakSelf.internalHandlers.onConnect?(nil)
      weakSelf.handlers.onConnect?(nil)
    }

    connectionStartTime = Date()
    connectionTimer.run {
      Logger.error(type: .mediaChannel, message: "connection timeout")
      self.internalDisconnect(error: SoraError.connectionTimeout, reason: .signalingFailure)
    }
  }

  /// 接続を解除します。
  ///
  /// - parameter error: 接続解除の原因となったエラー
  public func disconnect(error: Error?) {
    // reason に .user を指定しているので、 disconnect は SDK 内部では利用しない
    internalDisconnect(error: error, reason: .user)
  }

  func internalDisconnect(error: Error?, reason: DisconnectReason) {
    switch state {
    case .disconnecting, .disconnected:
      break

    default:
      // 接続の終了時に画面キャプチャを停止します。
      // 非同期で実行し、切断シーケンス自体はブロックしません。
      // スクリーンキャプチャ未使用時はインスタンス未生成のため何もしません。
      currentScreenCaptureController()?.stopCaptureForDisconnect()

      Logger.debug(type: .mediaChannel, message: "try disconnecting")
      if let error {
        Logger.error(
          type: .mediaChannel,
          message: "error: \(error.localizedDescription)")
      }

      if state == .connecting {
        executeHandler(error: error)
      }

      state = .disconnecting
      connectionTimer.stop()
      peerChannel.disconnect(error: error, reason: reason)
      Logger.debug(type: .mediaChannel, message: "did disconnect")
      state = .disconnected

      Logger.debug(type: .mediaChannel, message: "call onDisconnect")
      internalHandlers.onDisconnectLegacy?(error)
      handlers.onDisconnectLegacy?(error)

      // クロージャを用いて、エラーの内容に応じた SoraCloseEvent を生成
      // error が nil の場合はクライアントからの正常終了 or DataChannel のみのシグナリング利用時の正常終了として .ok にする
      // error が SoraError の場合はケースに応じて .ok と .error を切り替える
      // error が SoraError の場合はクライアントが disconnect に渡した error のため、そのまま .error とする
      let disconnectEvent: SoraCloseEvent = {
        guard let error = error else {
          return SoraCloseEvent.ok(code: 1000, reason: "NO-ERROR")
        }
        if let soraError = error as? SoraError {
          switch soraError {
          case .webSocketClosed(let code, let reason):
            // 基本的に reason が nil なるケースはないはずだが、nil の場合は空文字列とする
            return SoraCloseEvent.ok(code: code.intValue(), reason: reason ?? "")
          case .dataChannelClosed(let code, let reason):
            return SoraCloseEvent.ok(code: code, reason: reason)
          default:
            return SoraCloseEvent.error(error)
          }
        } else {
          return SoraCloseEvent.error(error)
        }
      }()

      handlers.onDisconnect?(disconnectEvent)
    }
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
        senderStream: SenderStreamBox(stream: senderStream),
        cameraSettings: CameraSettingsSnapshot(configuration.cameraSettings)
      )
    } else {
      // 画面キャプチャ動作中はカメラを再開しません
      guard !isScreenCaptureActive() else {
        throw SoraError.mediaChannelError(
          reason:
            "screen capture is active, stopScreenCapture before setVideoHardMute(false)")
      }

      // ハードミュート無効化 -> ソフトミュートによる黒塗りフレーム送出解除の順になるようにします
      try await Self.videoHardMuteActor.setMute(
        mute: false,
        senderStream: SenderStreamBox(stream: senderStream),
        cameraSettings: CameraSettingsSnapshot(configuration.cameraSettings)
      )
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

    // カメラキャプチャ動作中は開始できません
    guard !(await isCameraVideoCaptureRunning(on: senderStream)) else {
      throw SoraError.mediaChannelError(
        reason:
          "camera capture is running on senderStream, call setVideoHardMute(true) before startScreenCapture"
      )
    }

    let screenCaptureController = getOrCreateScreenCaptureController()

    try await screenCaptureController.startCapture(
      settings: settings,
      senderStream: senderStream
    )
    Logger.debug(type: .mediaChannel, message: "startScreenCapture")
  }

  /// ReplayKit を利用した画面キャプチャを停止します
  public func stopScreenCapture() async {
    let screenCaptureController = currentScreenCaptureController()
    await screenCaptureController?.stopCapture()
    Logger.debug(type: .mediaChannel, message: "stopScreenCapture")
  }

  /// 画面キャプチャが動作中かを取得します
  public func isScreenCaptureActive() -> Bool {
    currentScreenCaptureController()?.isCaptureActive() ?? false
  }

  // screenCaptureController インスタンスを取得します
  // インスタンス未生成の場合は生成します
  // スクリーンキャプチャ機能は必ず利用するとは限らないため必要時に生成しています
  private func getOrCreateScreenCaptureController() -> ScreenCaptureController {
    withScreenCaptureControllerLock {
      if let screenCaptureController {
        return screenCaptureController
      }

      let screenCaptureController = ScreenCaptureController(mediaChannel: self)
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
  private func isCameraVideoCaptureRunning(on senderStream: MediaStream) async -> Bool {
    await withCheckedContinuation { continuation in
      SoraDispatcher.async(on: .camera) {
        guard
          let current = CameraVideoCapturer.current,
          current.isRunning,
          let currentSenderStream = current.stream
        else {
          continuation.resume(returning: false)
          return
        }
        continuation.resume(returning: currentSenderStream === senderStream)
      }
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
