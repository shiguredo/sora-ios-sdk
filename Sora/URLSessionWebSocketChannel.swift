import Foundation
import Security

// URLSession を利用した WebSocket 通信用のクラスです。
// URLSession の delegateQueue と SignalingChannel 側の単一並行キューを前提に状態を扱うため、
// @unchecked Sendable を付与します。
final class URLSessionWebSocketChannel: NSObject, @unchecked Sendable, URLSessionDelegate,
  URLSessionTaskDelegate, URLSessionWebSocketDelegate
{
  let url: URL
  let proxy: Proxy?
  let caCertificates: [SecCertificate]?
  let insecure: Bool
  var handlers = WebSocketChannelHandlers()
  var internalHandlers = WebSocketChannelInternalHandlers()
  var isClosing = false

  var host: String {
    guard let host = url.host else {
      return url.absoluteString
    }
    return host
  }

  var urlSession: URLSession?
  var webSocketTask: URLSessionWebSocketTask?

  init(url: URL, proxy: Proxy?, caCertificates: [SecCertificate]?, insecure: Bool) {
    self.url = url
    self.proxy = proxy
    self.caCertificates = caCertificates
    self.insecure = insecure
  }

  func connect(delegateQueue: OperationQueue?) {
    let configuration = URLSessionConfiguration.ephemeral

    if let proxy {
      configuration.connectionProxyDictionary = [
        kCFNetworkProxiesHTTPProxy: proxy.host,
        kCFNetworkProxiesHTTPPort: proxy.port,
        kCFNetworkProxiesHTTPEnable: 1,

        // NOTE: `kCFStreamPropertyHTTPS` から始まるキーは deprecated になっているが、
        // それらを置き換える形で導入されたと思われる `kCFNetworkProxiesHTTPS` は、2022年6月時点で macOS からしか利用できない
        // https://developer.apple.com/documentation/cfnetwork/kcfnetworkproxieshttpsproxy
        //
        // 以下のページによるとバグではないか? とのこと
        // https://developer.apple.com/forums/thread/19356
        //
        // "HTTPSProxy", "HTTPSPort" などの文字列をキーの代わりに指定して Xcode の警告を消すことも可能
        kCFStreamPropertyHTTPSProxyHost: proxy.host,
        kCFStreamPropertyHTTPSProxyPort: proxy.port,

        // NOTE: kCFNetworkProxiesHTTPSProxy に相当するキーが `kCFStreamPropertyHTTPS` から始まるキーとして存在しなかったので、直接文字列で指定する
        // https://developer.apple.com/documentation/cfnetwork
        "HTTPSEnable": 1,
      ]

      Logger.info(
        type: .webSocketChannel,
        message:
          "proxy: \(String(describing: configuration.connectionProxyDictionary.debugDescription))"
      )
    }

    Logger.debug(type: .webSocketChannel, message: "[\(host)] connecting")
    urlSession = URLSession(
      configuration: configuration,
      delegate: self,
      delegateQueue: delegateQueue)

    webSocketTask = urlSession?.webSocketTask(with: url)

    webSocketTask?.resume()
    receive()
  }

  /// WebSocket を切断するメソッド
  ///
  /// クライアントから切断する場合は error を nil にする
  /// Sora から切断されたり、ネットワークエラーが起こったりした場合は error がセットされ、onDisconnectWithError コールバックが発火する
  func disconnect(error: Error?) {
    guard !isClosing else {
      return
    }

    isClosing = true
    Logger.debug(type: .webSocketChannel, message: "[\(host)] disconnecting")

    if let error {
      Logger.debug(
        type: .webSocketChannel,
        message: "[\(host)] error: \(error.localizedDescription)")
      internalHandlers.onDisconnectWithError?(self, error)
    }

    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    urlSession?.invalidateAndCancel()

    // メモリー・リークを防ぐために空の Handlers を設定する
    internalHandlers = WebSocketChannelInternalHandlers()

    Logger.debug(type: .webSocketChannel, message: "[\(host)] disconnected")
  }

  func send(message: WebSocketMessage) {
    let nativeMessage: URLSessionWebSocketTask.Message
    switch message {
    case .text(let text):
      Logger.debug(type: .webSocketChannel, message: "[\(host)] sending text: \(text)")
      nativeMessage = .string(text)
    case .binary(let data):
      Logger.debug(type: .webSocketChannel, message: "[\(host)] sending binary: \(data)")
      nativeMessage = .data(data)
    }
    guard let webSocketTask else {
      Logger.debug(type: .webSocketChannel, message: "[\(host)] webSocketTask is nil")
      return
    }
    webSocketTask.send(nativeMessage) { [weak self] error in
      guard let weakSelf = self else {
        return
      }

      // 余計なログを出力しないために、 disconnect の前にチェックする
      guard !weakSelf.isClosing else {
        return
      }

      if let error {
        Logger.debug(
          type: .webSocketChannel,
          message: "[\(weakSelf.host)] failed to send message: \(error.localizedDescription)")
        weakSelf.disconnect(error: SoraError.webSocketError(error))
      }
    }
  }

  func receive() {
    webSocketTask?.receive { [weak self] result in
      guard let weakSelf = self else {
        return
      }

      switch result {
      case .success(let message):
        Logger.debug(
          type: .webSocketChannel,
          message: "[\(weakSelf.host)] receive message => \(message)")

        var newMessage: WebSocketMessage?
        switch message {
        case .string(let string):
          newMessage = .text(string)
        case .data(let data):
          newMessage = .binary(data)
        @unknown default:
          break
        }

        if let message = newMessage {
          Logger.debug(
            type: .webSocketChannel, message: "[\(weakSelf.host)] call onReceive")
          weakSelf.handlers.onReceive?(message)
          weakSelf.internalHandlers.onReceive?(message)
        } else {
          Logger.debug(
            type: .webSocketChannel,
            message:
              "[\(weakSelf.host)] received message is not string or binary (discarded)"
          )
          // discard
        }

        weakSelf.receive()
      case .failure(let error):
        // メッセージ受信に失敗以上のエラーは urlSession の didCompleteWithError で検知できるのでここではログを出して break する
        Logger.debug(
          type: .webSocketChannel, message: "[\(weakSelf.host)] message receive error: \(error)")
      }
    }
  }

  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {
    guard !isClosing else {
      return
    }
    Logger.debug(type: .webSocketChannel, message: "[\(host)] \(#function)")
    if let onConnect = internalHandlers.onConnect {
      onConnect(self)
    }
  }

  func reason2string(reason: Data?) -> String? {
    guard let reason else {
      return nil
    }

    return String(data: reason, encoding: .utf8)
  }

  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
    reason: Data?
  ) {
    guard !isClosing else {
      return
    }

    Logger.debug(type: .webSocketChannel, message: "close frame received")
    var message = "[\(host)] \(#function) closeCode => \(closeCode)"

    let reasonString = reason2string(reason: reason)
    if reasonString != nil {
      message += " and reason => \(String(describing: reasonString))"
    }

    Logger.debug(type: .webSocketChannel, message: message)

    // 2025.2.x から、ステータスコード 1000 の場合でも error として上位層に伝搬させることにする (上位層が error 前提で組まれているためこのような方針にした)
    // TODO(zztkm): 改修範囲が広くはなるが Sora から正常に Close Frame を受け取った場合は error とは区別して伝搬させる
    let statusCode = WebSocketStatusCode(rawValue: closeCode.rawValue)
    let error = SoraError.webSocketClosed(
      statusCode: statusCode,
      reason: reasonString)
    disconnect(error: error)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    // コードを短くするために変数を定義
    let ps = challenge.protectionSpace
    let authMethod = ps.authenticationMethod
    let previousFailureCount = challenge.previousFailureCount

    // 既に失敗している場合はチャレンジを中止する
    guard previousFailureCount == 0 else {
      let message =
        "[\(host)] \(#function): Basic authentication failed. proxy => \(String(describing: proxy))"
      Logger.info(type: .webSocketChannel, message: message)
      completionHandler(.cancelAuthenticationChallenge, nil)

      // WebSocket 接続完了前のエラーなので webSocketError ではなく signalingChannelError として扱っている
      // webSocketError の場合、条件によっては Sora に type: disconnect を送信する必要があるが、今回は接続完了前なので不要
      disconnect(error: SoraError.signalingChannelError(reason: message))
      return
    }

    Logger.debug(
      type: .webSocketChannel,
      message:
        "[\(host)] \(#function): challenge=\(ps.host):\(ps.port), \(ps.authenticationMethod) previousFailureCount: \(previousFailureCount)"
    )

    // 認証方式によって処理を分岐
    switch authMethod {
    case NSURLAuthenticationMethodServerTrust:
      switch Self.resolveServerTrustDisposition(
        insecure: insecure, caCertificates: caCertificates)
      {
      case .skipVerification:
        guard let serverTrust = challenge.protectionSpace.serverTrust else {
          completionHandler(.cancelAuthenticationChallenge, nil)
          disconnect(error: SoraError.signalingChannelError(reason: "server trust is nil"))
          return
        }
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
      case .customCAVerification:
        handleServerTrustAuthenticationChallenge(
          challenge,
          completionHandler: completionHandler)
      case .defaultHandling:
        completionHandler(.performDefaultHandling, nil)
      }
    case NSURLAuthenticationMethodHTTPBasic:
      // basic 認証
      handleBasicAuthenticationChallenge(challenge, completionHandler: completionHandler)

    default:
      Logger.debug(
        type: .webSocketChannel,
        message:
          "[\(host)] \(#function): Unsupported or unhandled authentication method (\(authMethod)), performing default handling."
      )
      completionHandler(.performDefaultHandling, nil)
    }
  }

  // Proxy Authentication
  private func handleBasicAuthenticationChallenge(
    _ challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    // username と password をチェック
    guard let username = proxy?.username, let password = proxy?.password else {
      let message =
        "[\(host)] \(#function): Basic authentication required, but authentication information is insufficient. proxy => \(String(describing: proxy))"
      Logger.info(type: .webSocketChannel, message: message)
      completionHandler(.cancelAuthenticationChallenge, nil)

      // WebSocket 接続完了前のエラーなので webSocketError ではなく signalingChannelError として扱っている
      // webSocketError の場合、条件によっては Sora に type: disconnect を送信する必要があるが、今回は接続完了前なので不要
      disconnect(error: SoraError.signalingChannelError(reason: message))
      return
    }

    let credential = URLCredential(user: username, password: password, persistence: .forSession)
    completionHandler(.useCredential, credential)
  }

  // MARK: - サーバー証明書検証

  /// ServerTrust 認証チャレンジの解決方針を表します。
  enum ServerTrustDisposition: Equatable {
    /// 証明書検証をスキップし、全ての接続を許可する
    case skipVerification
    /// ユーザー指定 CA 証明書で検証する
    case customCAVerification
    /// システム既定の検証を行う
    case defaultHandling
  }

  /// ServerTrust 認証チャレンジの解決方針を返す。
  /// `insecure` と `caCertificates` の有無から方針を判定する。
  static func resolveServerTrustDisposition(
    insecure: Bool,
    caCertificates: [SecCertificate]?
  ) -> ServerTrustDisposition {
    if insecure {
      return .skipVerification
    } else if caCertificates != nil {
      return .customCAVerification
    } else {
      return .defaultHandling
    }
  }

  /// ユーザー指定 CA 証明書を用いてサーバー証明書を検証する
  ///
  /// 呼び出し元で `self.caCertificates` が非 nil であることを保証している前提で、
  /// `self.caCertificates` を直接参照する
  private func handleServerTrustAuthenticationChallenge(
    _ challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    // 呼び出し元で非 nil が保証されている
    // guard let による分岐直後のため安全
    // swiftlint:disable:next force_unwrapping
    let caCertificates = self.caCertificates!
    guard let serverTrust = challenge.protectionSpace.serverTrust else {
      let message =
        "[\(host)] \(#function): server trust is nil"
      Logger.info(type: .webSocketChannel, message: message)
      completionHandler(.cancelAuthenticationChallenge, nil)
      disconnect(error: SoraError.signalingChannelError(reason: message))
      return
    }

    if Self.evaluateServerTrust(serverTrust, withAnchorCertificates: caCertificates) {
      completionHandler(.useCredential, URLCredential(trust: serverTrust))
    } else {
      let message =
        "[\(host)] \(#function): server trust evaluation failed"
      Logger.info(type: .webSocketChannel, message: message)
      completionHandler(.cancelAuthenticationChallenge, nil)
      disconnect(error: SoraError.signalingChannelError(reason: message))
    }
  }

  /// SecTrust を指定 CA 証明書アンカーで評価する
  ///
  /// `Configuration.caCertificate` にはルート CA と中間 CA の両方が PEM で含まれている可能性があるが、
  /// `SecTrustSetAnchorCertificates` に中間 CA を渡すと、本来ルート CA の署名で検証すべき
  /// 中間 CA が無条件に信頼済みアンカーと見なされ、チェーン検証の強度が落ちる。
  /// そのため、発行者と主体が同一の自己署名証明書（ルート CA）のみをアンカーとして使用する
  static func evaluateServerTrust(
    _ serverTrust: SecTrust,
    withAnchorCertificates anchorCertificates: [SecCertificate]
  ) -> Bool {
    // ルート CA（自己署名証明書）のみをアンカーとして抽出する
    let rootAnchorCertificates = self.rootAnchorCertificates(from: anchorCertificates)
    guard !rootAnchorCertificates.isEmpty else { return false }
    let setAnchorsStatus = SecTrustSetAnchorCertificates(
      serverTrust, rootAnchorCertificates as CFArray)
    guard setAnchorsStatus == errSecSuccess else {
      Logger.debug(
        type: .webSocketChannel,
        message:
          "SecTrustSetAnchorCertificates failed with status \(setAnchorsStatus)")
      return false
    }
    let setAnchorsOnlyStatus = SecTrustSetAnchorCertificatesOnly(serverTrust, true)
    guard setAnchorsOnlyStatus == errSecSuccess else {
      Logger.debug(
        type: .webSocketChannel,
        message:
          "SecTrustSetAnchorCertificatesOnly failed with status \(setAnchorsOnlyStatus)")
      return false
    }
    var error: CFError?
    let result = SecTrustEvaluateWithError(serverTrust, &error)
    if !result, let error {
      let nsError = error as Error as NSError
      Logger.debug(
        type: .webSocketChannel,
        message:
          "server trust evaluate error: domain=\(nsError.domain), code=\(nsError.code), description=\(nsError.localizedDescription)"
      )
    }
    return result
  }

  /// 指定された証明書群から自己署名の root CA のみを抽出する
  ///
  /// root CA と中間 CA のみが含まれる証明書チェーンを想定しているため、
  /// subject と issuer 比較の簡易的なチェックにより抽出する
  static func rootAnchorCertificates(from certificates: [SecCertificate]) -> [SecCertificate] {
    certificates.filter { certificate in
      guard
        let subject = SecCertificateCopyNormalizedSubjectSequence(certificate) as Data?,
        let issuer = SecCertificateCopyNormalizedIssuerSequence(certificate) as Data?
      else {
        return false
      }
      return subject == issuer
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    // エラーが発生したときだけ disconnect 処理を投げる
    // ここで検知されるエラーの原因例: インターネット切断、Sora がダウン
    guard let error = error else { return }
    Logger.debug(
      type: .webSocketChannel, message: "didCompleteWithError \(error.localizedDescription)")
    disconnect(error: SoraError.webSocketError(error))
  }

}
