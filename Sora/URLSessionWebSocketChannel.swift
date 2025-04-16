import Foundation

@available(iOS 13, *)
class URLSessionWebSocketChannel: NSObject, URLSessionDelegate, URLSessionTaskDelegate,
  URLSessionWebSocketDelegate
{
  let url: URL
  let proxy: Proxy?
  let caCertificate: SecCertificate?  // カスタム CA 証明書を設定する場合はここに設定する
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

  init(url: URL, proxy: Proxy?, caCertificate: SecCertificate?) {
    self.url = url
    self.proxy = proxy
    self.caCertificate = caCertificate
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
    var nativeMessage: URLSessionWebSocketTask.Message!
    switch message {
    case .text(let text):
      Logger.debug(type: .webSocketChannel, message: "[\(host)] sending text: \(text)")
      nativeMessage = .string(text)
    case .binary(let data):
      Logger.debug(type: .webSocketChannel, message: "[\(host)] sending binary: \(data)")
      nativeMessage = .data(data)
    }
    webSocketTask!.send(nativeMessage) { [weak self] error in
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
      if let ca = caCertificate {
        // カスタム CA が設定されている場合はそれを使用してサーバー証明書を検証
        handleServerTrustChallenge(
          challenge, completionHandler: completionHandler, caCertificate: ca)
      } else {
        // カスタム CA が設定されていない場合はデフォルト処理
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

  private func handleServerTrustChallenge(
    _ challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void,
    caCertificate: SecCertificate
  ) {
    Logger.debug(type: .webSocketChannel, message: "handleServerTrustChallenge")
    guard let serverTrust = challenge.protectionSpace.serverTrust else {
      Logger.debug(type: .webSocketChannel, message: "handleServerTrustChallenge: no serverTrust")
      completionHandler(.performDefaultHandling, nil)
      return
    }
    // SecTrust オブジェクトにカスタム CA を信頼アンカーとして設定
    let policy = SecPolicyCreateBasicX509()  // 基本的な X.509 ポリシーを使用
    var ossStatus = SecTrustSetPolicies(serverTrust, policy)
    guard ossStatus == errSecSuccess else {
      Logger.warn(type: .webSocketChannel, message: "SecTrustSetPolicies failed")
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
    // カスタム CA を信頼アンカーとして追加
    // ここで追加されたアンカー以外の証明書は無視される（システムの証明書も無視される
    // https://developer.apple.com/documentation/security/sectrustsetanchorcertificatesonly(_:_:)
    let anchorCertificates = [caCertificate]
    ossStatus = SecTrustSetAnchorCertificates(serverTrust, anchorCertificates as CFArray)
    if ossStatus != errSecSuccess {
      Logger.warn(
        type: .webSocketChannel, message: "SecTrustSetAnchorCertificates failed: \(ossStatus)")
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }

    // システムの信頼ストアではなく、提供されたアンカーのみを使用するように強制
    // これにより、カスタムCAによって署名されていること *のみ* を検証できる
    let setOnlyStatus = SecTrustSetAnchorCertificatesOnly(serverTrust, true)
    guard setOnlyStatus == errSecSuccess else {
      // ログ出力はするが、致命的エラーとはしない場合もある
      Logger.warn(
        type: .webSocketChannel,
        message: "Warning: Could not set anchor certificates only: \(setOnlyStatus)")
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }

    // ホスト名の検証ポリシーを追加（デフォルトで含まれている場合もあるが明示的に行うのが安全）
    // 注意: wss:// スキームの場合、ポリシー作成時に "wss" ではなく "https" を使うことが多い
    // または、ホスト名検証をSecTrustEvaluateの後で別途行う方法もある
    //Logger.debug(type: .webSocketChannel, message: "\(host) を HTTPS サーバー名として検証")
    //let sslpolicy = SecPolicyCreateSSL(true, host as CFString)
    //let sslpolicyStatus = SecTrustSetPolicies(serverTrust, sslpolicy) // 必要に応じて
    //guard sslpolicyStatus == errSecSuccess else {
    //  Logger.warn(type: .webSocketChannel, message: "SecTrustSetPolicies failed: \(sslpolicyStatus)")
    //  completionHandler(.cancelAuthenticationChallenge, nil)
    //  return
    //}

    // サーバー証明書を評価
    var error: CFError?
    let trustResult = SecTrustEvaluateWithError(serverTrust, &error)

    if trustResult {
      // 信頼できると評価された場合はサーバーの証明書を使って認証情報を作成する
      Logger.debug(type: .webSocketChannel, message: "Server trust evaluation succeeded")
      completionHandler(.useCredential, URLCredential(trust: serverTrust))
    } else {
      Logger.warn(
        type: .webSocketChannel,
        message: "Server trust evaluation failed: \(error?.localizedDescription ?? "Unknown error")"
      )
      completionHandler(.cancelAuthenticationChallenge, nil)
    }

  }

  // --- Helper: Proxy Authentication ---
  private func handleBasicAuthenticationChallenge(
    _ challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    // 既存の Proxy Basic 認証ロジックを流用
    let ps = challenge.protectionSpace
    let previousFailureCount = challenge.previousFailureCount

    // 既に失敗している場合はチャレンジを中止する
    guard previousFailureCount == 0 else {
      let message =
        "[\(host)] \(#function): Proxy authentication failed (previous failure count: \(previousFailureCount)). Proxy => \(String(describing: proxy))"
      Logger.info(type: .webSocketChannel, message: message)
      completionHandler(.cancelAuthenticationChallenge, nil)
      disconnect(error: SoraError.signalingChannelError(reason: message))  // disconnect は適切か要確認
      return
    }

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

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    // エラーが発生したときだけ disconnect 処理を投げる
    // ここで検知されるエラーの原因例: インターネット切断、Sora がダウン
    guard let error = error else { return }
    Logger.debug(
      type: .webSocketChannel, message: "didCompleteWithError \(error.localizedDescription)")
    disconnect(error: SoraError.webSocketError(error))
  }
}
