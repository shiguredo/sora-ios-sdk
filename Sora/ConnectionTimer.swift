import Foundation

enum ConnectionMonitor {
    
    case webSocketChannel(WebSocketChannel)
    case signalingChannel(SignalingChannel)
    case peerChannel(PeerChannel)
    
    var state: ConnectionState {
        get {
            switch self {
            case .webSocketChannel(let chan):
                return chan.state
            case .signalingChannel(let chan):
                return chan.state
            case .peerChannel(let chan):
                return chan.state
            }
        }
    }
    
    func disconnect() {
        let error = SoraError.connectionTimeout
        switch self {
        case .webSocketChannel(let chan):
            chan.disconnect(error: error)
        case .signalingChannel(let chan):
            chan.disconnect(error: error)
        case .peerChannel(let chan):
            chan.disconnect(error: error)
        }
    }
    
}

class ConnectionTimer {
    
    public var monitors: [ConnectionMonitor]
    public var timeout: Int
    public var isRunning: Bool = false
    
    private var timer: Timer?
    
    public init(monitors: [ConnectionMonitor], timeout: Int) {
        self.monitors = monitors
        self.timeout = timeout
    }
    
    public func run(timeout: Int? = nil, handler: @escaping () -> Void) {
        if let timeout = timeout {
            self.timeout = timeout
        }
        Logger.debug(type: .connectionTimer,
                     message: "run (timeout: \(self.timeout) seconds)")

        timer = Timer(timeInterval: TimeInterval(self.timeout), repeats: false)
        { timer in
            Logger.debug(type: .connectionTimer, message: "validate timeout")
            for monitor in self.monitors {
                if monitor.state.isConnecting {
                    Logger.debug(type: .connectionTimer,
                                 message: "found timeout")
                    for monitor in self.monitors {
                        if !monitor.state.isDisconnected {
                            monitor.disconnect()
                        }
                    }
                    handler()
                    self.stop()
                    return
                }
            }
            Logger.debug(type: .connectionTimer, message: "all OK")
        }
        RunLoop.main.add(timer!, forMode: RunLoop.Mode.common)
        isRunning = true
    }
    
    public func stop() {
        Logger.debug(type: .connectionTimer, message: "stop")
        timer?.invalidate()
        isRunning = false
    }
    
}
