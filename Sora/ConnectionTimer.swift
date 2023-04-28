import Foundation

enum ConnectionMonitor {
    case signalingChannel(SignalingChannel)
    case peerChannel(PeerChannel)

    var state: ConnectionState {
        switch self {
        case let .signalingChannel(chan):
            return chan.state
        case let .peerChannel(chan):
            return ConnectionState(chan.state)
        }
    }

    func disconnect() {
        let error = SoraError.connectionTimeout
        switch self {
        case let .signalingChannel(chan):
            // タイムアウトはシグナリングのエラーと考える
            chan.disconnect(error: error, reason: .signalingFailure)
        case let .peerChannel(chan):
            // タイムアウトはシグナリングのエラーと考える
            chan.disconnect(error: error, reason: .signalingFailure)
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
        if let timeout {
            self.timeout = timeout
        }
        Logger.debug(type: .connectionTimer,
                     message: "run (timeout: \(self.timeout) seconds)")

        timer = Timer(timeInterval: TimeInterval(self.timeout), repeats: false) { _ in
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
