import Foundation

public enum AliveState {
    case available
    case unavailable
    case connecting
}

public protocol AliveMonitorable: class {
    
    var aliveState: AliveState { get }
    
}

final class AliveMonitor {
    
    public var isRunning: Bool {
        get { return !(timer != nil && timer!.isValid) }
    }
    
    public var objects: [AliveMonitorable] = []
    
    public var onObserveHandler: (([AliveMonitorable]) -> Void)?
    public var onChangeHandler: (([AliveMonitorable]) -> Void)?

    private var timer: Timer?

    public func addObject(_ object: AliveMonitorable) {
        objects.append(object)
    }
    
    public func run(timeInterval: TimeInterval) {
        Logger.debug(type: .aliveMonitor, message: "run")
        timer = Timer(timeInterval: timeInterval, repeats: true) { timer in
            Logger.trace(type: .aliveMonitor,
                      message: "validate available state")
            self.onObserveHandler?(self.objects)

            var changed: [AliveMonitorable] = []
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
