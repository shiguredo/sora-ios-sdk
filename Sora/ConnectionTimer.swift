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

/// `ConnectionTimer.run` の timeout handler を `Timer` の block へ渡すための、
/// 用途限定の内部ラッパーです。
///
/// `@unchecked Sendable` を認める根拠は、次の 3 条件をすべて満たすことです。
/// - 可変状態を持たず、保持する handler は `init` で確定した `let` であること
/// - 変更前から handler を渡していた `Timer` の block を包み直すだけで、配送先・
///   通知順序・呼び出し回数を変えず、別系統の境界へ新たに渡さないこと
/// - 保持するのは handler の closure だけで、SDK 内部の参照型を新たに保持しないこと
///
/// 生成は `ConnectionTimer.run` の 1 箇所だけで、1 つの `Timer` の block へ 1 回だけ渡し、
/// 世代照合を通過した timeout 経路から高々 1 回だけ呼ぶ使用契約です (型では強制されません)。
/// `Sendable` にするのはこの入れ物だけで、handler とその捕捉状態を `Sendable` にはしません。
/// 捕捉状態の所有と同期は、呼び出しスレッドを保証しない既存の挙動の下で利用者の責務です。
/// 実行スレッドの同一性・直列性も契約にしません。
private final class ConnectionTimerHandlerBox: @unchecked Sendable {
  private let handler: () -> Void

  init(_ handler: @escaping () -> Void) {
    self.handler = handler
  }

  func callAsFunction() {
    handler()
  }
}

class ConnectionTimer: @unchecked Sendable {
  public var monitors: [ConnectionMonitor]
  public var timeout: Int
  private var _isRunning = false

  /// Timer の状態 (`timer` / `isRunning` / `generation`) を保護する排他ロック。
  /// `run()` と `stop()` は接続処理・切断処理・Timer callback など異なるスレッドから
  /// 呼ばれるため、状態の読み書きをこのロックで直列化する。
  private let stateLock = NSLock()

  private var timer: Timer?

  /// Timer が現在有効かどうかを返します。
  public var isRunning: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return _isRunning
  }

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

  /// Timer を開始します。
  ///
  /// - returns: この呼び出しで有効になった timeout (秒)。呼び出し元が排他区間の外で
  ///   開始ログを出すために使います。
  @discardableResult
  public func run(timeout: Int? = nil, handler: @escaping () -> Void) -> Int {
    // timeout handler は `@Sendable` ではないため、公開している引数の型を変えずに box へ包む。
    // block の `[weak self]` と `self.monitors` の読み方は変えない。
    let handlerBox = ConnectionTimerHandlerBox(handler)

    stateLock.lock()
    if let timeout {
      self.timeout = timeout
    }
    // 有効な timeout はこの時点で確定する。Timer の interval と戻り値 (開始ログ) を
    // 同じ値にするため、lock を保持している間に 1 回だけ取り出す。
    let effectiveTimeout = self.timeout

    // run() の再実行時に残っている旧 Timer を必ず無効化する。
    // (invalidate しないと main RunLoop に残った旧 Timer が発火し、
    // 現在の接続を timeout として切断してしまう)
    timer?.invalidate()
    timer = nil
    generation += 1
    let currentGeneration = generation

    let createdTimer = Timer(timeInterval: TimeInterval(effectiveTimeout), repeats: false) {
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
          handlerBox()
          self.stop()
          return
        }
      }
      Logger.debug(type: .connectionTimer, message: "all OK")
    }
    timer = createdTimer
    RunLoop.main.add(createdTimer, forMode: RunLoop.Mode.common)
    _isRunning = true
    stateLock.unlock()
    return effectiveTimeout
  }

  public func stop() {
    stateLock.lock()
    // invalidate 前に RunLoop へ配送されたものの、まだ世代照合を通過していない callback を
    // 拒否できるよう、稼働中の Timer を停止するときは世代を進める。
    if timer != nil {
      generation += 1
    }
    // timer を nil 化しないと ConnectionTimer → Timer → closure → self の
    // 循環参照が残り、接続完了・切断後も ConnectionTimer が解放されない。
    timer?.invalidate()
    timer = nil
    _isRunning = false
    stateLock.unlock()

    // ログは排他区間の外で出す。ロックを保持したまま Logger を呼ぶと、利用者の
    // onOutputHandler が同じ lock を取る経路で deadlock する。
    Logger.debug(type: .connectionTimer, message: "stop")
  }
}
