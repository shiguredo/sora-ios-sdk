import Foundation

@available(iOS 13, *)
class URLSessionWebSocketChannel: WebSocketChannel {

    public var url: URL
    public var sslEnabled: Bool = true
    public var handlers: WebSocketChannelHandlers = WebSocketChannelHandlers()
    public var internalHandlers: WebSocketChannelHandlers = WebSocketChannelHandlers()

    public var state: ConnectionState {
        get { return context.state }
    }

    var context: URLSessionWebSocketChannelContext!
    
    public required init(url: URL) {
        self.url = url
        context = URLSessionWebSocketChannelContext(channel: self)
    }
    
    public func connect(handler: @escaping (Error?) -> Void) {
        context.connect(handler: handler)
    }
    
    public func disconnect(error: Error?) {
        context.disconnect(error: error)
    }
    
    public func send(message: WebSocketMessage) {
        Logger.debug(type: .webSocketChannel, message: "send message")
        context.send(message: message)
    }

}

@available(iOS 13, *)
class URLSessionWebSocketChannelContext: NSObject, URLSessionDelegate, URLSessionTaskDelegate, URLSessionWebSocketDelegate {
    
    weak var channel: URLSessionWebSocketChannel?
    var urlSession: URLSession?
    var webSocketTask: URLSessionWebSocketTask?
    
    var state: ConnectionState = .disconnected {
        didSet {
            Logger.trace(type: .webSocketChannel,
                      message: "changed state from \(oldValue) to \(state)")
        }
    }
    
    var onConnect: ((Error?) -> Void)?

    init(channel: URLSessionWebSocketChannel) {
        self.channel = channel
        super.init()
    }
    
    func connect(handler: @escaping (Error?) -> Void) {
        guard let channel = channel else {
            return
        }

        if channel.state.isConnecting {
            handler(SoraError.connectionBusy(reason:
                "WebSocketChannel is already connected"))
            return
        }
        
        Logger.debug(type: .webSocketChannel, message: "try connecting")
        state = .connecting
        onConnect = handler
        urlSession = URLSession(configuration: .default,
                                delegate: self,
                                delegateQueue: nil)
        webSocketTask = urlSession?.webSocketTask(with: channel.url)
        webSocketTask?.resume()
        receive()
    }
    
    func disconnect(error: Error?) {
        guard let channel = channel else {
            webSocketTask?.cancel(with: .normalClosure, reason: nil)
            urlSession?.invalidateAndCancel()
            return
        }

        switch state {
        case .disconnecting, .disconnected:
            break
            
        default:
            Logger.debug(type: .webSocketChannel, message: "try disconnecting")
            if error != nil {
                Logger.debug(type: .webSocketChannel,
                             message: "error: \(error!.localizedDescription)")
            }
            
            state = .disconnecting
            webSocketTask?.cancel(with: .normalClosure, reason: nil)
            urlSession?.invalidateAndCancel()
            state = .disconnected
            
            Logger.debug(type: .webSocketChannel, message: "call onDisconnect")
            channel.internalHandlers.onDisconnect?(error)
            channel.handlers.onDisconnect?(error)
            
            if onConnect != nil {
                Logger.debug(type: .webSocketChannel, message: "call connect(handler:) handler")
                onConnect!(error)
                onConnect = nil
            }
            
            Logger.debug(type: .webSocketChannel, message: "did disconnect")
        }
    }
    
    func send(message: WebSocketMessage) {
        var naviveMessage: URLSessionWebSocketTask.Message!
        switch message {
        case .text(let text):
            Logger.debug(type: .webSocketChannel, message: text)
            naviveMessage = .string(text)
        case .binary(let data):
            Logger.debug(type: .webSocketChannel, message: "\(data)")
            naviveMessage = .data(data)
        }
        webSocketTask!.send(naviveMessage) { [weak self] error in
            guard let weakSelf = self else {
                return
            }
            if let error = error {
                Logger.debug(type: .webSocketChannel, message: "failed to send message")
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
                Logger.debug(type: .webSocketChannel, message: "receive message => \(message)")
                
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
                    Logger.debug(type: .webSocketChannel, message: "call onReceive")
                    weakSelf.channel?.internalHandlers.onReceive?(message)
                    weakSelf.channel?.handlers.onReceive?(message)
                } else {
                    Logger.debug(type: .webSocketChannel,
                              message: "received message is not string or binary (discarded)")
                    // discard
                }
                
                weakSelf.receive()
                
            case .failure(let error):
                Logger.debug(type: .webSocketChannel,
                             message: "failed to receive error => \(error.localizedDescription)")
                weakSelf.disconnect(error: error)
            }
        }
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        Logger.debug(type: .webSocketChannel, message: "connected")
        state = .connected
        if onConnect != nil {
            Logger.debug(type: .webSocketChannel, message: "call connect(handler:) handler")
            onConnect!(nil)
            onConnect = nil
        }
    }
    
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        Logger.debug(type: .webSocketChannel,
                     message: "closed with code => \(closeCode.rawValue)")
        
        var reasonString: String?
        if let reason = reason {
            reasonString = String(data: reason, encoding: .utf8)
            if let string = reasonString {
                Logger.debug(type: .webSocketChannel,
                             message: "reason => \(string)")
            }
        }
        if closeCode != .normalClosure {
            let statusCode = WebSocketStatusCode(rawValue: closeCode.rawValue)
            let error = SoraError.webSocketClosed(statusCode: statusCode,
                                                  reason: reasonString)
            disconnect(error: error)
        }
    }
    
}
