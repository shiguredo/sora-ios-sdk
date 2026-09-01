import Foundation

enum ConnectionMonitor {
  case signalingChannel(SignalingChannel)
  case peerChannel(PeerChannel)

  var state: ConnectionState {
    switch self {
    case .signalingChannel(let chan):
      return chan.state
    case .peerChannel(let chan):
      return ConnectionState(chan.state)
    }
  }

  func disconnect() {
    let error = SoraError.connectionTimeout
    switch self {
    case .signalingChannel(let chan):
      // タイムアウトはシグナリングのエラーと考える
      chan.disconnect(error: error, reason: .signalingFailure)
    case .peerChannel(let chan):
      // タイムアウトはシグナリングのエラーと考える
      chan.disconnect(error: error, reason: .signalingFailure)
    }
  }
}

class ConnectionTimer: @unchecked Sendable {
  public var monitors: [ConnectionMonitor]
  public var timeout: Int
  public var isRunning: Bool = false

  /// Timer の状態 (`timer` / `isRunning` / `generation`) を保護する排他ロック。
  /// `run()` と `stop()` は接続処理・切断処理・Timer callback など異なるスレッドから
  /// 呼ばれるため、状態の読み書きをこのロックで直列化する。
  private let stateLock = NSLock()

  private var timer: Timer?

  /// Timer ごとの生成世代。`run()` のたびに +1 し、callback 発火時に現在の世代と
  /// 一致する場合のみ timeout 処理を実行する。
  /// (invalidate 済みの old Timer が main RunLoop から遅れて発火しても、
  /// 現在の接続試行を切断しないための防御。PeerChannel の disconnectTimerGeneration と同じ概念)
  private var generation: Int = 0

  /// テストから現在の生成世代を確認するための内部アクセサ。
  /// (実運用では使用しない。generation の管理と検証のために公開する)
  var currentGeneration: Int {
    stateLock.lock()
    defer { stateLock.unlock() }
    return generation
  }

  public init(monitors: [ConnectionMonitor], timeout: Int) {
    self.monitors = monitors
    self.timeout = timeout
  }

  public func run(timeout: Int? = nil, handler: @escaping () -> Void) {
    stateLock.lock()
    if let timeout {
      self.timeout = timeout
    }
    Logger.debug(
      type: .connectionTimer,
      message: "run (timeout: \(self.timeout) seconds)")

    // run() の再実行時に残っている旧 Timer を必ず無効化する。
    // (invalidate しないと main RunLoop に残った旧 Timer が発火し、
    // 現在の接続を timeout として切断してしまう)
    timer?.invalidate()
    timer = nil
    generation += 1
    let currentGeneration = generation

    let createdTimer = Timer(timeInterval: TimeInterval(self.timeout), repeats: false) {
      [weak self] _ in
      guard let self else {
        return
      }
      // 旧世代の Timer が発火した場合は何もしない (現在の接続を切断しない)。
      // 世代の比較は lock 配下で行う (stop() による世代更新と競合しない)
      self.stateLock.lock()
      guard self.generation == currentGeneration else {
        self.stateLock.unlock()
        return
      }
      // monitor の状態取得は lock 配下でなくても良いが、disconnect / handler を
      // lock 配下で呼ぶと、内部 lock を保持したまま再入するため lock 外で呼ぶ
      let monitors = self.monitors
      self.stateLock.unlock()

      Logger.debug(type: .connectionTimer, message: "validate timeout")
      for monitor in monitors {
        if monitor.state.isConnecting {
          Logger.debug(
            type: .connectionTimer,
            message: "found timeout")
          for monitor in monitors {
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
    timer = createdTimer
    guard let timer else {
      stateLock.unlock()
      return
    }
    RunLoop.main.add(timer, forMode: RunLoop.Mode.common)
    isRunning = true
    stateLock.unlock()
  }

  public func stop() {
    stateLock.lock()
    Logger.debug(type: .connectionTimer, message: "stop")
    // timer を nil 化しないと ConnectionTimer → Timer → closure → self の
    // 循環参照が残り、接続完了・切断後も ConnectionTimer が解放されない。
    timer?.invalidate()
    timer = nil
    isRunning = false
    stateLock.unlock()
  }
}
