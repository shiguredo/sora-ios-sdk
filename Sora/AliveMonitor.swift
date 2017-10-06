import Foundation

enum AliveState {
    case available
    case unavailable
    case connecting
}

enum AliveMonitored {
    
    case webSocketChannel(WebSocketChannel)
    case signalingChannel(SignalingChannel)
    case peerChannel(PeerChannel)
    case mediaChannel(MediaChannel)
    
    var aliveState: AliveState {
        switch self {
        case .webSocketChannel(let chan):
            switch chan.state {
            case .connected:
                return .available
            case .connecting:
                return .connecting
            case .disconnecting, .disconnected:
                return .unavailable
            }
            
        case .signalingChannel(let chan):
            switch chan.state {
            case .connected:
                return .available
            case .connecting:
                return .connecting
            case .disconnecting, .disconnected:
                return .unavailable
            }
            
        case .peerChannel(let chan):
            switch chan.state {
            case .connected:
                return .available
            case .connecting:
                return .connecting
            default:
                return .unavailable
            }
            
        case .mediaChannel(let chan):
            switch chan.state {
            case .connected:
                return .available
            case .disconnecting, .disconnected:
                return .unavailable
            default:
                return .connecting
            }
        }
    }
    
}

final class AliveMonitor {
    
    public var isRunning: Bool {
        get { return !(timer != nil && timer!.isValid) }
    }
    
    public var objects: [AliveMonitored] = []
    
    public var onObserveHandler: (([AliveMonitored]) -> Void)?
    public var onChangeHandler: (([AliveMonitored]) -> Void)?
    
    private var timer: Timer?
    
    public func addObject(_ object: AliveMonitored) {
        objects.append(object)
    }
    
    public func run(timeInterval: TimeInterval) {
        Logger.debug(type: .aliveMonitor, message: "run")
        timer = Timer(timeInterval: timeInterval, repeats: true) { timer in
            Logger.trace(type: .aliveMonitor,
                         message: "validate available state")
            self.onObserveHandler?(self.objects)
            
            var changed: [AliveMonitored] = []
            for object in self.objects {
                
                switch object.aliveState {
                case .available, .connecting:
                    break
                case .unavailable:
                    Logger.debug(type: .aliveMonitor,
                                 message: "found unavailable state \(object)")
                    changed.append(object)
                }
            }
            if !changed.isEmpty {
                self.onChangeHandler?(changed)
            }
        }
        RunLoop.main.add(timer!, forMode: .commonModes)
    }
    
    public func stop() {
        Logger.debug(type: .aliveMonitor, message: "stop")
        timer!.invalidate()
        timer = nil
    }
    
}
