import Foundation

public enum AliveState {
    case available
    case unavailable
    case connecting
}

public protocol AliveMonitorable: class {
    
    var aliveState: AliveState { get }
    
}

public final class AliveMonitor {
    
    public var isRunning: Bool {
        get { return !(timer != nil && timer!.isValid) }
    }
    
    public var objects: [AliveMonitorable] = []
    
    private var timer: Timer?

    private var onObserveHandler: Callback1<[AliveMonitorable], Void> = Callback1(repeats: true)
    private var onChangeHandler: Callback1<[AliveMonitorable], Void> = Callback1(repeats: true)

    public func addObject(_ object: AliveMonitorable) {
        objects.append(object)
    }
    
    public func run(timeInterval: TimeInterval) {
        Log.debug(type: .aliveMonitor, message: "run")
        timer = Timer(timeInterval: timeInterval, repeats: true) { timer in
            Log.trace(type: .aliveMonitor,
                      message: "validate available state")
            self.onObserveHandler.execute(self.objects)

            var changed: [AliveMonitorable] = []
            for object in self.objects {

                switch object.aliveState {
                case .available, .connecting:
                    break
                case .unavailable:
                    Log.debug(type: .aliveMonitor,
                              message: "found unavailable state \(object)")
                    changed.append(object)
                }
            }
            if !changed.isEmpty {
                self.onChangeHandler.execute(changed)
            }
        }
        RunLoop.main.add(timer!, forMode: .commonModes)
    }
    
    public func stop() {
        Log.debug(type: .aliveMonitor, message: "stop")
        timer!.invalidate()
        timer = nil
    }
    
    public func onObserve(handler: @escaping ([AliveMonitorable]) -> Void) {
        onObserveHandler.onExecute(handler: handler)
    }
    
    public func onChange(handler: @escaping ([AliveMonitorable]) -> Void) {
        onChangeHandler.onExecute(handler: handler)
    }
    
}
