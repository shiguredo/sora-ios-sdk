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

    // SignalingChannel で利用する WebSocket
    var webSocketChannel: URLSessionWebSocketChannel?

    // SignalingChannel で利用する WebSocket の候補
    //
    // 接続に失敗した WebSocket は候補から削除される
    // SignalingChannel で利用する WebSocket が決定する前に候補が無くなった場合、
    // Sora への接続に失敗しているため、 MediaChannel の接続処理を終了する必要がある
    //
    // また、 SignalingChannel で利用する WebSocket が決定した場合にも空になる
    var webSocketChannelCandidates: [URLSessionWebSocketChannel] = []

    private var onConnectHandler: ((Error?) -> Void)?

    // WebSocket の接続を複数同時に試行する際の排他制御を行うためのキュー
    //
    // このキューの並行性を1に設定した上で URLSession の delegateQueue に設定することで、
    // URLSession のコールバックが同時に発火することを防ぎます
    private let queue: OperationQueue

    // 最初に type: connect を送信した URL
    var contactUrl: URL?

    // type: offer を Sora から受信したタイミングで設定する
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

    private func setUpWebSocketChannel(url: URL, proxy: Proxy?) -> URLSessionWebSocketChannel {
        let ws = URLSessionWebSocketChannel(url: url, proxy: proxy)

        // 接続成功時
        ws.internalHandlers.onConnect = { [weak self] webSocketChannel in
            guard let weakSelf = self else {
                return
            }

            // 最初に接続に成功した WebSocket 以外は無視する
            guard weakSelf.webSocketChannel == nil else {
                // (接続に失敗した WebSocket と同様に、) 無視した WebSocket を webSocketChannelCandidates から削除することを検討したが、不要と判断した
                //
                // 最初の WebSocket が接続に成功した際に webSocketChannelCandidates をクリアするため、
                // 既に webSocketChannelCandidates が空になっていることが理由
                return
            }

            // 接続に成功した WebSocket を SignalingChannel に設定する
            Logger.info(type: .signalingChannel, message: "connected to \(String(describing: ws.host))")
            weakSelf.webSocketChannel = webSocketChannel
            if weakSelf.contactUrl == nil {
                weakSelf.contactUrl = ws.url
            }
            // 採用された WebSocket 以外を切断してから webSocketChannelCandidates をクリアする
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

        // エラー発生時
        ws.internalHandlers.onDisconnectWithError = { [weak self] ws, error in
            guard let weakSelf = self else {
                return
            }
            Logger.info(type: .signalingChannel, message: "disconnected from \(String(describing: ws.host))")

            if weakSelf.state == .connected {
                // SignalingChannel で利用する WebSocket が決定した後に、 WebSocket のエラーが発生した場合の処理
                // ignoreDisconnectWebSocket の値をチェックして SDK の接続処理を終了する
                if !weakSelf.ignoreDisconnectWebSocket {
                    weakSelf.disconnect(error: error, reason: .webSocket)
                }
            } else {
                // SignalingChannel で利用する WebSocket が決定する前に、 WebSocket のエラーが発生した場合の処理
                // state が .disconnecting, .disconnected の場合もここを通るが、既に SignalingChannel の切断を開始しているため、考慮は不要

                // 接続に失敗した WebSocket が候補に残っている場合取り除く
                weakSelf.webSocketChannelCandidates.removeAll { $0.url.absoluteURL == ws.url.absoluteURL }

                // 候補が無くなり、かつ SignalingChannel で利用する WebSocket が決まっていない場合、
                // Sora への接続に失敗したので SDK の接続処理を終了する
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
            let ws = setUpWebSocketChannel(url: url, proxy: configuration.proxy)
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

        // 接続
        guard let newUrl = URL(string: location) else {
            let message = "invalid message: \(location)"
            Logger.error(type: .signalingChannel, message: message)
            disconnect(error: SoraError.signalingChannelError(reason: message), reason: DisconnectReason.signalingFailure)
            return
        }

        let ws = setUpWebSocketChannel(url: newUrl, proxy: configuration.proxy)
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

            contactUrl = nil
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
            var data = try encoder.encode(message)

            // type: connect の data_channels を設定する
            // Signaling.encode(to:) では Any を扱えなかったため、文字列に変換する直前に値を設定している
            switch message {
            case .connect:
                if configuration.dataChannels != nil {
                    var jsonObject = try (JSONSerialization.jsonObject(with: data, options: [])) as! [String: Any]
                    jsonObject["data_channels"] = configuration.dataChannels
                    data = try JSONSerialization.data(withJSONObject: jsonObject, options: [])
                }
            default:
                break
            }

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

    func setConnectedUrl() {
        guard let ws = webSocketChannel else {
            return
        }
        connectedUrl = ws.url
    }
}
