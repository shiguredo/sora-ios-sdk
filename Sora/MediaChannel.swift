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

  /// シグナリング受信時に呼ばれるクロージャー
  public var onReceiveSignaling: ((Signaling) -> Void)?

  /// シグナリングが DataChannel 経由に切り替わったタイミングで呼ばれるクロージャー
  public var onDataChannel: ((MediaChannel) -> Void)?

  /// DataChannel のメッセージ受信時に呼ばれるクロージャー
  public var onDataChannelMessage: ((MediaChannel, String, Data) -> Void)?

  /// RPC のレスポンスを受信したときに呼ばれるクロージャー
  public var onReceiveRPCResponse: ((MediaChannel, RPCResponse) -> Void)?

  /// RPC のエラー応答を受信したときに呼ばれるクロージャー
  public var onReceiveRPCError: ((MediaChannel, RPCErrorDetail) -> Void)?

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

  /// RPC を扱うチャネル
  public var rpcChannel: RPCChannel? {
    peerChannel.rpcChannel
  }

  /// RPC で利用可能なメソッド一覧
  public var rpcMethods: [RPCMethod] {
    peerChannel.rpcChannel?.allowedMethods ?? []
  }

  /// RPC で利用可能なサイマルキャスト rid
  public var rpcSimulcastRids: [String] {
    peerChannel.rpcChannel?.simulcastRpcRids ?? []
  }

  // MARK: 接続チャネル

  /// シグナリングチャネル
  let signalingChannel: SignalingChannel

  /// ピアチャネル
  var peerChannel: PeerChannel {
    _peerChannel!
  }

  // PeerChannel に mediaChannel を保持させる際にこの書き方が必要になった
  private var _peerChannel: PeerChannel?

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
    _connectionTimer!
  }

  // PeerChannel に mediaChannel を保持させる際にこの書き方が必要になった
  private var _connectionTimer: ConnectionTimer?

  private let manager: Sora

  // MARK: - インスタンスの生成

  /// 初期化します。
  ///
  /// - parameter manager: `Sora` オブジェクト
  /// - parameter configuration: クライアントの設定
  init(manager: Sora, configuration: Configuration) {
    self.manager = manager
    self.configuration = configuration
    signalingChannel = SignalingChannel.init(configuration: configuration)
    _peerChannel = PeerChannel.init(
      configuration: configuration,
      signalingChannel: signalingChannel,
      mediaChannel: self)
    handlers = configuration.mediaChannelHandlers

    _connectionTimer = ConnectionTimer(
      monitors: [
        .signalingChannel(signalingChannel),
        .peerChannel(_peerChannel!),
      ],
      timeout: configuration.connectionTimeout)
  }

  // MARK: - RPC

  /// RPC を送信する。
  @discardableResult
  public func callRPC(
    method: RPCMethod,
    params: Encodable? = nil,
    expectsResponse: Bool = true,
    timeout: TimeInterval = 5.0,
    completion: ((Result<RPCResponse, SoraError>) -> Void)? = nil
  ) -> Bool {
    guard let rpcChannel else {
      completion?(.failure(SoraError.rpcUnavailable(reason: "rpc channel is not available")))
      return false
    }
    return rpcChannel.call(
      method: method,
      params: params,
      expectsResponse: expectsResponse,
      timeout: timeout,
      completion: completion)
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
    connectionTask.peerChannel = peerChannel

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

    peerChannel.connect { [weak self] error in
      guard let weakSelf = self else {
        return
      }

      weakSelf.connectionTimer.stop()
      connectionTask.complete()

      if let error {
        Logger.error(type: .mediaChannel, message: "failed to connect")
        weakSelf.internalDisconnect(error: error, reason: .signalingFailure)
        handler(error)

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
