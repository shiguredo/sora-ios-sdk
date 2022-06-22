import Foundation

@available(iOS 13, *)
class URLSessionWebSocketChannel: NSObject, URLSessionDelegate, URLSessionTaskDelegate, URLSessionWebSocketDelegate {
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

        if let proxy = proxy {
            // TODO: Basic 認証が1回成功すると、結果が一定時間キャッシュされている模様
            // 具体的には urlSession(_:didReceive:completionHandler:) が authenticationMethod: NSURLAuthenticationMethodHTTPBasic で呼ばれなくなる
            // ただ、サーバー側で tshark を使って (*1) 確認したところ、 CONNECT メッセージに Proxy-Authorization ヘッダーは付与されている
            // URLSession のキャッシュを消すべく試行錯誤したが改善することができなかった
            //
            // *1 ... 確認時に使用した tshark のコマンド: tshark -V -Y 'http.request.method == "CONNECT"'
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.urlCredentialStorage = nil

            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable: 1,
                kCFNetworkProxiesHTTPProxy: proxy.host,
                kCFNetworkProxiesHTTPPort: proxy.port,

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
            ]

            Logger.info(type: .webSocketChannel, message: "proxy: \(String(describing: configuration.connectionProxyDictionary.debugDescription))")
        }

        Logger.debug(type: .webSocketChannel, message: "[\(host)] connecting")
        urlSession = URLSession(configuration: configuration,
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

        if let error = error {
            Logger.debug(type: .webSocketChannel,
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
        case let .text(text):
            Logger.debug(type: .webSocketChannel, message: text)
            nativeMessage = .string(text)
        case let .binary(data):
            Logger.debug(type: .webSocketChannel, message: "[\(host)] \(data)")
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

            if let error = error {
                Logger.debug(type: .webSocketChannel, message: "[\(weakSelf.host)] failed to send message")
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
            case let .success(message):
                Logger.debug(type: .webSocketChannel, message: "[\(weakSelf.host)] receive message => \(message)")

                var newMessage: WebSocketMessage?
                switch message {
                case let .string(string):
                    newMessage = .text(string)
                case let .data(data):
                    newMessage = .binary(data)
                @unknown default:
                    break
                }

                if let message = newMessage {
                    Logger.debug(type: .webSocketChannel, message: "[\(weakSelf.host)] call onReceive")
                    weakSelf.handlers.onReceive?(message)
                    weakSelf.internalHandlers.onReceive?(message)
                } else {
                    Logger.debug(type: .webSocketChannel,
                                 message: "[\(weakSelf.host)] received message is not string or binary (discarded)")
                    // discard
                }

                weakSelf.receive()

            case let .failure(error):
                // 余計なログを出力しないために、 disconnect の前にチェックする
                guard !weakSelf.isClosing else {
                    return
                }

                Logger.debug(type: .webSocketChannel,
                             message: "[\(weakSelf.host)] failed => \(error.localizedDescription)")
                weakSelf.disconnect(error: SoraError.webSocketError(error))
            }
        }
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?)
    {
        guard !isClosing else {
            return
        }
        Logger.debug(type: .webSocketChannel, message: "[\(host)] \(#function)")
        if let onConnect = internalHandlers.onConnect {
            onConnect(self)
        }
    }

    func reason2string(reason: Data?) -> String? {
        guard let reason = reason else {
            return nil
        }

        return String(data: reason, encoding: .utf8)
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?)
    {
        guard !isClosing else {
            return
        }

        var message = "[\(host)] \(#function) closeCode => \(closeCode)"

        let reasonString = reason2string(reason: reason)
        if reasonString != nil {
            message += " and reason => \(String(describing: reasonString))"
        }

        Logger.debug(type: .webSocketChannel, message: message)

        if closeCode != .normalClosure {
            let statusCode = WebSocketStatusCode(rawValue: closeCode.rawValue)
            let error = SoraError.webSocketClosed(statusCode: statusCode,
                                                  reason: reasonString)
            disconnect(error: error)
        }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        Logger.debug(type: .webSocketChannel, message: "[\(host)] \(#function) didReceive: challenge=\(challenge.protectionSpace.host):\(challenge.protectionSpace.port), \(challenge.protectionSpace.authenticationMethod)")

        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic:
            guard let username = proxy?.username, let password = proxy?.password else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            let credential = URLCredential(user: username, password: password, persistence: URLCredential.Persistence.forSession)
            completionHandler(.useCredential, credential)
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
