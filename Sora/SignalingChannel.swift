import AVFoundation
import Foundation

/**
 ストリームの方向を表します。
 シグナリングメッセージで使われます。
 */
public enum SignalingRole: String {
    /// この列挙子は sendonly に置き換えられました。
    @available(*, deprecated, renamed: "sendonly",
               message: "この列挙子は sendonly に置き換えられました。")
    case upstream

    /// この列挙子は recvonly に置き換えられました。
    @available(*, deprecated, renamed: "recvonly",
               message: "この列挙子は recvonly に置き換えられました。")
    case downstream

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
@available(*, unavailable, message: "MediaChannelHandlers を利用してください。")
public class SignalingChannelHandlers {}

class SignalingChannelInternalHandlers {
    /// 接続解除時に呼ばれるクロージャー
    var onDisconnect: ((Error?, DisconnectReason) -> Void)?

    /// シグナリング受信時に呼ばれるクロージャー
    var onReceive: ((Signaling) -> Void)?

    /// シグナリング送信時に呼ばれるクロージャー
    var onSend: ((Signaling) -> Signaling)?

    /// 初期化します。
    init() {}
}

class SignalingChannel {
    var internalHandlers = SignalingChannelInternalHandlers()

    var ignoreDisconnectWebSocket: Bool = false
    var dataChannelSignaling: Bool = false

    var configuration: Configuration

    var state: ConnectionState = .disconnected {
        didSet {
            Logger.trace(type: .signalingChannel,
                         message: "changed state from \(oldValue) to \(state)")
        }
    }

    var webSocketChannel: URLSessionWebSocketChannel?
    var webSocketChannelCandidates: [URLSessionWebSocketChannel] = []

    private var onConnectHandler: ((Error?) -> Void)?

    private let queue: OperationQueue

    var connectedUrl: URL?

    required init(configuration: Configuration) {
        self.configuration = configuration

        let queue = OperationQueue()
        queue.name = "jp.shiguredo.sora-ios-sdk.websocket-delegate"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        self.queue = queue
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

    private func setUpWebSocketChannel(url: URL) -> URLSessionWebSocketChannel {
        let ws = URLSessionWebSocketChannel(url: url)

        // 接続時
        ws.internalHandlers.onConnect = { [weak self] webSocketChannel in
            guard let weakSelf = self else {
                return
            }

            // 最初に接続に成功した WebSocket 以外は無視する
            guard weakSelf.webSocketChannel == nil else {
                return
            }

            Logger.info(type: .signalingChannel, message: "connected to \(String(describing: ws.host))")
            weakSelf.webSocketChannel = webSocketChannel
            weakSelf.connectedUrl = ws.url

            // 採用された WebSocket 以外を切断してから webSocketChannelCandidates を破棄する
            weakSelf.webSocketChannelCandidates.removeAll { $0 == webSocketChannel }

            weakSelf.webSocketChannelCandidates.forEach {
                Logger.debug(type: .signalingChannel, message: "closeing connection to \(String(describing: $0.host))")
                $0.disconnect(error: nil)
            }

            weakSelf.webSocketChannelCandidates.removeAll()
            weakSelf.state = .connected

            if weakSelf.onConnectHandler != nil {
                Logger.debug(type: .signalingChannel, message: "call connect(handler:)")
                weakSelf.onConnectHandler!(nil)
            }
        }

        // 切断時
        ws.internalHandlers.onDisconnectWithError = { [weak self] ws, error in
            guard let weakSelf = self else {
                return
            }
            Logger.info(type: .signalingChannel, message: "disconnected from \(String(describing: ws.host))")

            if weakSelf.state == .connected {
                if !weakSelf.ignoreDisconnectWebSocket {
                    weakSelf.disconnect(error: error, reason: .webSocket)
                }
            } else {
                // 接続に失敗した WebSocket が候補に残っている場合取り除く
                weakSelf.webSocketChannelCandidates.removeAll { $0.url.absoluteURL == ws.url.absoluteURL }

                if weakSelf.webSocketChannelCandidates.count == 0, weakSelf.webSocketChannel == nil {
                    Logger.info(type: .signalingChannel, message: "failed to connect to Sora")
                    if !weakSelf.ignoreDisconnectWebSocket {
                        weakSelf.disconnect(error: error, reason: .webSocket)
                    }
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
        if state.isConnecting {
            handler(SoraError.connectionBusy(reason:
                "SignalingChannel is already connected"))
            return
        }

        Logger.debug(type: .signalingChannel, message: "try connecting")
        onConnectHandler = handler
        state = .connecting

        let urlCandidates = unique(urls: configuration.urlCandidates)
        Logger.info(type: .signalingChannel, message: "urlCandidates: \(urlCandidates)")
        for url in urlCandidates {
            let ws = setUpWebSocketChannel(url: url)
            Logger.info(type: .signalingChannel, message: "connecting to \(String(describing: ws.url))")
            ws.connect(delegateQueue: queue)
            webSocketChannelCandidates.append(ws)
        }
    }

    func redirect(location: String) {
        Logger.debug(type: .signalingChannel, message: "try redirecting to \(location)")
        state = .connecting

        // 切断
        webSocketChannel?.disconnect(error: nil)
        webSocketChannel = nil
        connectedUrl = nil

        // 接続
        guard let newUrl = URL(string: location) else {
            let message = "invalid message: \(location)"
            Logger.error(type: .signalingChannel, message: message)
            disconnect(error: SoraError.signalingChannelError(reason: message), reason: DisconnectReason.signalingFailure)
            return
        }

        let ws = setUpWebSocketChannel(url: newUrl)
        ws.connect(delegateQueue: queue)
    }

    func disconnect(error: Error?, reason: DisconnectReason) {
        switch state {
        case .disconnecting, .disconnected:
            break
        default:
            Logger.debug(type: .signalingChannel, message: "try disconnecting")
            if let error = error {
                Logger.error(type: .signalingChannel,
                             message: "error: \(error.localizedDescription)")
            }

            state = .disconnecting
            webSocketChannel?.disconnect(error: nil)
            webSocketChannelCandidates.forEach { $0.disconnect(error: nil) }
            state = .disconnected

            Logger.debug(type: .signalingChannel, message: "call onDisconnect")
            internalHandlers.onDisconnect?(error, reason)

            connectedUrl = nil
            Logger.debug(type: .signalingChannel, message: "did disconnect")
        }
    }

    func send(message: Signaling) {
        guard let ws = webSocketChannel else {
            Logger.info(type: .signalingChannel, message: "failed to unwrap webSocketChannel")
            return
        }

        Logger.debug(type: .signalingChannel, message: "send message")
        let message = internalHandlers.onSend?(message) ?? message
        let encoder = JSONEncoder()
        do {
            let data = try encoder.encode(message)
            let str = String(data: data, encoding: .utf8)!
            Logger.debug(type: .signalingChannel, message: str)
            ws.send(message: .text(str))
        } catch {
            Logger.debug(type: .signalingChannel,
                         message: "JSON encoding failed")
        }
    }

    func send(text: String) {
        guard let ws = webSocketChannel else {
            Logger.info(type: .signalingChannel, message: "failed to unwrap webSocketChannel")
            return
        }

        ws.send(message: .text(text))
    }

    func handle(message: WebSocketMessage) {
        Logger.debug(type: .signalingChannel, message: "receive message")
        switch message {
        case .binary:
            Logger.debug(type: .signalingChannel, message: "discard binary message")

        case let .text(text):
            guard let data = text.data(using: .utf8) else {
                Logger.error(type: .signalingChannel, message: "invalid encoding")
                return
            }

            switch Signaling.decode(data) {
            case let .success(signaling):
                Logger.debug(type: .signalingChannel, message: "call onReceiveSignaling")
                internalHandlers.onReceive?(signaling)
            case let .failure(error):
                Logger.error(type: .signalingChannel,
                             message: "decode failed (\(error.localizedDescription)) => \(text)")
            }
        }
    }
}
