import Foundation

public class ConnectionTimer {
    
    public weak var target: AliveMonitorable?
    public var timeout: Int
    public var isRunning: Bool = false
    
    private var timer: Timer?
    private var onTimeoutHandler: (() -> Void)?
    
    public init(target: AliveMonitorable? = nil, timeout: Int) {
        self.target = target
        self.timeout = timeout
    }
    
    // target がセットされている場合、タイムアウト時に target の状態が
    // connecting の場合のみタイムアウトとして扱うので、明示的に stop を呼ぶ必要はない
    public func run(timeout: Int? = nil, handler: @escaping () -> Void) {
        if let timeout = timeout {
            self.timeout = timeout
        }
        onTimeoutHandler = handler
        timer = Timer(timeInterval: TimeInterval(self.timeout), repeats: false)
        { timer in
            self.stop()
            if let target = self.target {
                switch target.aliveState {
                case .connecting:
                    self.onTimeoutHandler?()
                default:
                    break
                }
            } else {
                self.onTimeoutHandler?()
            }
            self.onTimeoutHandler = nil
        }
        RunLoop.main.add(timer!, forMode: .commonModes)
        isRunning = true
    }
    
    public func stop() {
        timer?.invalidate()
        isRunning = false
    }
    
}
