import Foundation

@available(iOS 13, *)
class URLSessionWebSocketChannel: NSObject, URLSessionDelegate, URLSessionTaskDelegate,
  URLSessionWebSocketDelegate
{
  let url: URL
  let proxy: Proxy?
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

  init(url: URL, proxy: Proxy?) {
    self.url = url
    self.proxy = proxy
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

    Logger.debug(type: .webSocketChannel, message: "[\(host)] canceling")
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
      Logger.debug(type: .webSocketChannel, message: "[\(host)] sending text: \(text)]")
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
        weakSelf.disconnect(error: error)
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
        break
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
    Logger.debug(type: .webSocketChannel, message: "close frame received")
    guard !isClosing else {
      return
    }

    Logger.debug(type: .webSocketChannel, message: "close frame received but not yet closing")

    var message = "[\(host)] \(#function) closeCode => \(closeCode)"

    let reasonString = reason2string(reason: reason)
    if reasonString != nil {
      message += " and reason => \(String(describing: reasonString))"
    }

    Logger.debug(type: .webSocketChannel, message: message)

    if closeCode != .normalClosure {
      let statusCode = WebSocketStatusCode(rawValue: closeCode.rawValue)
      let error = SoraError.webSocketClosed(
        statusCode: statusCode,
        reason: reasonString)
      disconnect(error: error)
    }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    // コードを短くするために変数を定義
    let ps = challenge.protectionSpace
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

    // Basic 認証のみに対応している
    // それ以外の認証方法は .performDefaultHandling で処理を続ける
    guard ps.authenticationMethod == NSURLAuthenticationMethodHTTPBasic else {
      completionHandler(.performDefaultHandling, nil)
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
}
