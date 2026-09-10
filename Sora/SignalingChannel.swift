import AVFoundation
import Foundation
import Security

/// ストリームの方向を表します。
/// シグナリングメッセージで使われます。
public enum SignalingRole: String, Sendable {
  /// 送信のみ
  case sendonly

  /// 受信のみ
  case recvonly

  /// 送受信
  case sendrecv
}

/**
 シグナリングチャネルのイベントハンドラです。
 */

class SignalingChannelInternalHandlers {
  /// 接続解除時に呼ばれるクロージャー
  var onDisconnect: ((Error?, DisconnectReason) -> Void)?

  /// シグナリング受信時に呼ばれるクロージャー
  var onReceive: ((Signaling) -> Void)?

  /// シグナリング受信時に JSON 文字列で呼ばれるクロージャー
  var onReceiveJSON: ((String) -> Void)?

  /// シグナリング送信時に呼ばれるクロージャー
  var onSend: ((Signaling) -> Signaling)?

  /// 初期化します。
  init() {}
}

class SignalingChannel {
  var internalHandlers = SignalingChannelInternalHandlers()

  var configuration: Configuration

  // 接続状態の単一所有者。
  // 状態の読み書きと WebSocket の操作はすべてこの owner の直列 queue 上で行う。
  private let owner = SignalingStateOwner()

  // MARK: - 同期 getter

  /// 接続状態
  var state: ConnectionState {
    owner.snapshot.state.phase.connectionState
  }

  /// 最初に type: connect を送信した URL
  var contactUrl: URL? {
    owner.snapshot.state.contactUrl
  }

  /// type: offer を Sora から受信したタイミングで設定する URL
  var connectedUrl: URL? {
    owner.snapshot.state.connectedUrl
  }

  /// DataChannel シグナリングを利用するかどうか
  var dataChannelSignaling: Bool {
    get {
      owner.snapshot.state.dataChannelSignaling
    }
    set {
      owner.sync {
        owner.handle(.dataChannelSignalingUpdated(newValue))
      }
    }
  }

  /// DataChannel シグナリングへの切り替え後に WebSocket の切断を無視するかどうか
  var ignoreDisconnectWebSocket: Bool {
    get {
      owner.snapshot.state.ignoreDisconnectWebSocket
    }
    set {
      owner.sync {
        owner.handle(.ignoreDisconnectWebSocketUpdated(newValue))
      }
    }
  }

  /// 現在使用中の WebSocket の識別子。
  ///
  /// WebSocket の切断は `disconnectWebSocket(identifier:)` を通して行い、
  /// Channel の参照自体は外部に公開しない。
  var webSocketChannelIdentifier: ObjectIdentifier? {
    owner.snapshot.currentChannelIdentifier
  }

  required init(configuration: Configuration) {
    self.configuration = configuration
  }

  private func unique(urls: [URL]) -> [URL] {
    var uniqueUrls: [URL] = []
    for url in urls {
      var contains = false
      for uniqueUrl in uniqueUrls {
        if url.absoluteString == uniqueUrl.absoluteString {
          contains = true
          break
        }
      }

      if !contains {
        uniqueUrls.append(url)
      }
    }

    return uniqueUrls
  }

  private func setUpWebSocketChannel(url: URL, proxy: Proxy?, caCertificates: [SecCertificate]?)
    -> URLSessionWebSocketChannel
  {
    let ws = URLSessionWebSocketChannel(
      url: url, proxy: proxy, caCertificates: caCertificates,
      insecure: configuration.insecure)

    // 接続成功時 (URLSession の delegate queue は owner の queue と同じため、
    // このクロージャは owner の queue 上で呼ばれる)
    ws.internalHandlers.onConnect = { [weak self] webSocketChannel in
      guard let weakSelf = self else {
        return
      }

      // リダイレクトで開始した接続試行が切断後に遅れて成功した場合は受け入れない。
      // (正当な採用時点は .connecting (初回接続・リダイレクト) と .connected のみ。
      // .disconnecting / .disconnected で受け入れると、connect メッセージの再送や
      // サーバーセッションの残留につながるため)
      let state = weakSelf.owner.currentState
      guard state.phase == .connecting || state.phase == .connected else {
        webSocketChannel.disconnect(error: nil)
        return
      }

      // 最初に接続に成功した WebSocket 以外は無視する
      guard weakSelf.owner.currentChannelOnQueue() == nil else {
        return
      }

      // 接続に成功した WebSocket を現在使用中の WebSocket に設定する
      Logger.info(
        type: .signalingChannel,
        message: "connected to \(String(describing: webSocketChannel.host))")
      weakSelf.owner.setCurrentChannel(webSocketChannel)
      weakSelf.owner.handle(.candidateConnected(url: webSocketChannel.url))

      // 採用された WebSocket 以外を切断してから候補をクリアする
      weakSelf.owner.removeCandidate(webSocketChannel)
      for candidate in weakSelf.owner.candidatesOnQueue() {
        Logger.debug(
          type: .signalingChannel,
          message: "closeing connection to \(String(describing: candidate.host))")
        candidate.disconnect(error: nil)
      }
      weakSelf.owner.clearCandidates()

      if let onConnect = weakSelf.owner.takeOnConnect() {
        Logger.debug(type: .signalingChannel, message: "call connect(handler:)")
        onConnect(nil)
      }
    }

    // WebSocket 切断時
    // 正常に切断したときも error は nil にならない
    ws.internalHandlers.onDisconnectWithError = { [weak self] ws, error in
      guard let weakSelf = self else {
        return
      }
      Logger.info(
        type: .signalingChannel, message: "disconnected from \(String(describing: ws.host))"
      )

      let state = weakSelf.owner.currentState
      if state.phase == .connected {
        // SignalingChannel で利用する WebSocket が決定した後に、 WebSocket のエラーが発生した場合の処理
        // ignoreDisconnectWebSocket の値をチェックして SDK の接続処理を終了する
        if !state.ignoreDisconnectWebSocket {
          weakSelf.disconnect(error: error, reason: .webSocket)
        }
      } else {
        // SignalingChannel で利用する WebSocket が決定する前に、 WebSocket のエラーが発生した場合の処理
        // state が .disconnecting, .disconnected の場合もここを通るが、既に SignalingChannel の切断を開始しているため、考慮は不要

        // 接続に失敗した WebSocket が候補に残っている場合取り除く
        weakSelf.owner.removeCandidate(ws)

        // 候補が無くなり、かつ SignalingChannel で利用する WebSocket が決まっていない場合、
        // Sora への接続に失敗したので SDK の接続処理を終了する
        // (ignoreDisconnectWebSocket は接続確立後の WebSocket 切断に対する扱いであり、
        // 接続確立前 (currentChannel == nil) の接続失敗には適用しない。
        // 適用すると redirect 先への接続失敗が検出不能になり、state が .connecting のまま
        // 終端しないため)
        if weakSelf.owner.candidatesOnQueue().isEmpty,
          weakSelf.owner.currentChannelOnQueue() == nil
        {
          Logger.info(type: .signalingChannel, message: "failed to connect to Sora")
          weakSelf.disconnect(error: error, reason: .webSocket)
        }
      }
    }

    ws.handlers = configuration.webSocketChannelHandlers
    // メッセージ受信時
    ws.internalHandlers.onReceive = { [weak self] message in
      self?.handle(message: message)
    }

    return ws
  }

  func connect(handler: @escaping (Error?) -> Void) {
    owner.sync {
      if owner.currentState.phase == .connecting {
        handler(
          SoraError.connectionBusy(
            reason:
              "SignalingChannel is already connected"))
        return
      }

      Logger.debug(type: .signalingChannel, message: "try connecting")
      owner.setOnConnect(handler)
      owner.handle(.connectRequested)

      if configuration.insecure {
        Logger.warn(
          type: .signalingChannel,
          message: "insecure mode is enabled: WebSocket TLS certificate verification is skipped")
      }

      // CA 証明書のパース
      let caCertificates: [SecCertificate]?
      do {
        caCertificates = try configuration.parsedCACertificates()
      } catch {
        Logger.error(
          type: .signalingChannel,
          message: "failed to parse CA certificate: \(error.localizedDescription)")
        owner.handle(.connectionFailed)
        if let onConnect = owner.takeOnConnect() {
          onConnect(error)
        }
        return
      }

      let urlCandidates = unique(urls: configuration.urlCandidates)
      Logger.info(type: .signalingChannel, message: "urlCandidates: \(urlCandidates)")
      for url in urlCandidates {
        let ws = setUpWebSocketChannel(
          url: url, proxy: configuration.proxy, caCertificates: caCertificates)
        Logger.info(
          type: .signalingChannel, message: "connecting to \(String(describing: ws.url))")
        ws.connect(delegateQueue: owner.queue)
        owner.addCandidate(ws)
      }
    }
  }

  func redirect(location: String) {
    owner.sync {
      Logger.debug(type: .signalingChannel, message: "try redirecting to \(location)")
      owner.handle(.redirectRequested)

      if configuration.insecure {
        Logger.warn(
          type: .signalingChannel,
          message: "insecure mode is enabled: WebSocket TLS certificate verification is skipped")
      }

      // 切断
      owner.currentChannelOnQueue()?.disconnect(error: nil)
      owner.setCurrentChannel(nil)

      // 接続
      guard let newUrl = URL(string: location) else {
        let message = "invalid message: \(location)"
        Logger.error(type: .signalingChannel, message: message)
        disconnect(
          error: SoraError.signalingChannelError(reason: message),
          reason: DisconnectReason.signalingFailure)
        return
      }

      // CA 証明書のパース
      let caCertificates: [SecCertificate]?
      do {
        caCertificates = try configuration.parsedCACertificates()
      } catch {
        Logger.error(
          type: .signalingChannel,
          message: "failed to parse CA certificate: \(error.localizedDescription)")
        disconnect(error: error, reason: .signalingFailure)
        return
      }

      let ws = setUpWebSocketChannel(
        url: newUrl, proxy: configuration.proxy, caCertificates: caCertificates)
      ws.connect(delegateQueue: owner.queue)
    }
  }

  func disconnect(error: Error?, reason: DisconnectReason) {
    owner.sync {
      switch owner.currentState.phase {
      case .disconnecting, .disconnected:
        break
      case .connecting, .connected:
        Logger.debug(type: .signalingChannel, message: "try disconnecting")
        if let error {
          Logger.error(
            type: .signalingChannel,
            message: "error: \(error.localizedDescription)")
        }

        owner.handle(.disconnectRequested)
        owner.currentChannelOnQueue()?.disconnect(error: nil)
        for candidate in owner.candidatesOnQueue() {
          candidate.disconnect(error: nil)
        }
        owner.handle(.disconnectCompleted)

        Logger.debug(type: .signalingChannel, message: "call onDisconnect")
        internalHandlers.onDisconnect?(error, reason)

        owner.handle(.urlsCleared)
        Logger.debug(type: .signalingChannel, message: "did disconnect")
      }
    }
  }

  /// 現在使用中の WebSocket が指定された識別子と一致する場合に切断します。
  ///
  /// redirect などで WebSocket が切り替わっている場合は何もしません。
  func disconnectWebSocket(identifier: ObjectIdentifier) {
    owner.disconnectChannel(identifier: identifier)
  }

  func send(message: Signaling) {
    owner.sync {
      guard let ws = owner.currentChannelOnQueue() else {
        Logger.info(type: .signalingChannel, message: "failed to unwrap webSocketChannel")
        return
      }

      Logger.debug(type: .signalingChannel, message: "send message")
      let message = internalHandlers.onSend?(message) ?? message
      let encoder = JSONEncoder()
      do {
        var data = try encoder.encode(message)

        // type: connect の data_channels を設定する
        // Signaling.encode(to:) では Any を扱えなかったため、文字列に変換する直前に値を設定している
        switch message {
        case .connect:
          if configuration.dataChannels != nil {
            var jsonObject =
              try (JSONSerialization.jsonObject(with: data, options: []))
              as! [String: Any]
            jsonObject["data_channels"] = configuration.dataChannels
            data = try JSONSerialization.data(withJSONObject: jsonObject, options: [])
          }
        default:
          break
        }

        let str = String(data: data, encoding: .utf8) ?? ""
        Logger.debug(type: .signalingChannel, message: str)
        ws.send(message: .text(str))
      } catch {
        Logger.debug(
          type: .signalingChannel,
          message: "JSON encoding failed")
      }
    }
  }

  func send(text: String) {
    owner.sync {
      guard let ws = owner.currentChannelOnQueue() else {
        Logger.info(type: .signalingChannel, message: "failed to unwrap webSocketChannel")
        return
      }

      ws.send(message: .text(text))
    }
  }

  func handle(message: WebSocketMessage) {
    Logger.debug(type: .signalingChannel, message: "receive message")
    switch message {
    case .binary:
      Logger.debug(type: .signalingChannel, message: "discard binary message")

    case .text(let json):
      internalHandlers.onReceiveJSON?(json)
      guard let data = json.data(using: .utf8) else {
        Logger.error(type: .signalingChannel, message: "invalid encoding")
        return
      }

      switch Signaling.decode(data) {
      case .success(let signaling):
        Logger.debug(type: .signalingChannel, message: "call onReceiveSignaling")
        internalHandlers.onReceive?(signaling)
      case .failure(let error):
        Logger.error(
          type: .signalingChannel,
          message: "decode failed (\(error.localizedDescription)) => \(json)")
      }
    }
  }

  func setConnectedUrl() {
    owner.sync {
      guard let ws = owner.currentChannelOnQueue() else {
        return
      }
      owner.handle(.connectedUrlSet(url: ws.url))
    }
  }
}
