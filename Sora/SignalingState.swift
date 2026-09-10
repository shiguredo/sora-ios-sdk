import Foundation

/// SignalingChannel の接続 phase を表します。
enum SignalingPhase: Sendable {
  /// 切断済み
  case disconnected

  /// 接続試行中
  case connecting

  /// 接続済み
  case connected

  /// 切断試行中
  case disconnecting

  /// 公開 API の `ConnectionState` へ変換する。
  var connectionState: ConnectionState {
    switch self {
    case .disconnected:
      return .disconnected
    case .connecting:
      return .connecting
    case .connected:
      return .connected
    case .disconnecting:
      return .disconnecting
    }
  }
}

/// SignalingChannel の状態。
///
/// 状態は単一所有者である `SignalingStateOwner` が所有し、
/// その他のスレッドは NSLock で保護された snapshot を通じてのみ観測する。
struct SignalingState: Sendable {
  /// 接続 phase
  var phase: SignalingPhase = .disconnected

  /// 最初に type: connect を送信した URL
  var contactUrl: URL?

  /// type: offer を Sora から受信したタイミングで設定する URL
  var connectedUrl: URL?

  /// DataChannel シグナリングを利用するかどうか
  var dataChannelSignaling: Bool = false

  /// DataChannel シグナリングへの切り替え後に WebSocket の切断を無視するかどうか
  var ignoreDisconnectWebSocket: Bool = false
}

/// SignalingChannel の状態を駆動するイベント。
enum SignalingEvent: Sendable {
  /// 接続開始
  case connectRequested

  /// 接続候補の WebSocket が接続に成功した
  case candidateConnected(url: URL)

  /// 接続に失敗した (候補が尽きた)
  case connectionFailed

  /// redirect を受信した
  case redirectRequested

  /// 切断開始
  case disconnectRequested

  /// 切断完了
  case disconnectCompleted

  /// 接続 URL のクリア (切断完了通知の後に送る)
  case urlsCleared

  /// type: offer を受信して接続 URL が確定した
  case connectedUrlSet(url: URL)

  /// dataChannelSignaling の更新
  case dataChannelSignalingUpdated(Bool)

  /// ignoreDisconnectWebSocket の更新
  case ignoreDisconnectWebSocketUpdated(Bool)
}

/// reducer が返す副作用。
enum SignalingEffect: Sendable {
  /// 状態の更新を snapshot に publish する
  case publishSnapshot
}

/// SignalingChannel の状態 reducer。
///
/// (State, Event) を入力として、次の State と副作用のリストを返す純粋関数。
/// イベントは呼び出し側のガードを通過したもののみが渡される。
enum SignalingStateReducer {
  /// イベントを処理し、次の State と副作用を返す。
  static func reduce(
    state: SignalingState,
    event: SignalingEvent
  ) -> (state: SignalingState, effects: [SignalingEffect]) {
    var state = state
    var effects: [SignalingEffect] = []

    switch event {
    // 接続開始: 接続試行中のみ拒否する (呼び出し側の busy 判定と同じ)
    case .connectRequested:
      if state.phase != .connecting {
        state.phase = .connecting
        effects.append(.publishSnapshot)
      }

    // 最初に接続に成功した WebSocket のみ採用する
    case .candidateConnected(let url):
      if state.phase != .connected {
        state.phase = .connected
        if state.contactUrl == nil {
          state.contactUrl = url
        }
        effects.append(.publishSnapshot)
      }

    // 候補が尽きた場合は接続失敗として終端する
    case .connectionFailed:
      state.phase = .disconnected
      effects.append(.publishSnapshot)

    // redirect では新しい接続試行を開始する (contactUrl は維持する)
    case .redirectRequested:
      state.phase = .connecting
      effects.append(.publishSnapshot)

    // 切断開始: 既に切断中・切断済みの場合は無視する
    case .disconnectRequested:
      switch state.phase {
      case .disconnecting, .disconnected:
        break
      case .connecting, .connected:
        state.phase = .disconnecting
        effects.append(.publishSnapshot)
      }

    // 切断完了: phase のみ変更する (URL のクリアは切断完了通知の後)
    case .disconnectCompleted:
      state.phase = .disconnected
      effects.append(.publishSnapshot)

    // 接続 URL のクリア
    case .urlsCleared:
      state.contactUrl = nil
      state.connectedUrl = nil
      effects.append(.publishSnapshot)

    case .connectedUrlSet(let url):
      state.connectedUrl = url
      effects.append(.publishSnapshot)

    case .dataChannelSignalingUpdated(let value):
      state.dataChannelSignaling = value
      effects.append(.publishSnapshot)

    case .ignoreDisconnectWebSocketUpdated(let value):
      state.ignoreDisconnectWebSocket = value
      effects.append(.publishSnapshot)
    }

    return (state, effects)
  }
}

/// SignalingChannel の状態の単一所有者。
///
/// 状態と接続候補の管理を直列 queue 上で行う。URLSession の delegateQueue にも
/// 同じ queue を設定することで、delegate callback と操作の順序を確定する。
final class SignalingStateOwner: @unchecked Sendable {
  /// 操作と URLSession delegate callback を直列化する queue。
  /// URLSession の delegateQueue にはこの queue を設定する。
  let queue: OperationQueue

  /// queue の直列化と再入検出に利用する DispatchQueue。
  private let dispatchQueue: DispatchQueue

  /// 再入検出用の queue 識別子。
  private let queueKey = DispatchSpecificKey<Void>()

  /// 現在の状態 (queue 上でのみ読み書きする)
  private var state = SignalingState()

  /// 現在使用中の WebSocket (queue 上でのみ読み書きする)
  private var currentChannel: URLSessionWebSocketChannel?

  /// 接続候補の WebSocket (queue 上でのみ読み書きする)
  private var candidates: [URLSessionWebSocketChannel] = []

  /// 接続完了 handler (queue 上でのみ読み書きする)
  private var onConnect: ((Error?) -> Void)?

  /// 同期 getter 用の snapshot storage
  private let snapshotStorage = SignalingSnapshotStorage()

  init() {
    let dispatchQueue = DispatchQueue(
      label: "jp.shiguredo.sora-ios-sdk.signaling-owner")
    dispatchQueue.setSpecific(key: queueKey, value: ())
    self.dispatchQueue = dispatchQueue

    let queue = OperationQueue()
    queue.name = "jp.shiguredo.sora-ios-sdk.websocket-delegate"
    queue.maxConcurrentOperationCount = 1
    queue.qualityOfService = .userInteractive
    queue.underlyingQueue = dispatchQueue
    self.queue = queue
  }

  /// owner の queue 上で同期的に block を実行する。
  ///
  /// すでに queue 上で実行中の場合は直接実行し、デッドロックを避ける。
  /// (delegate callback から操作 API を呼ぶ再入経路で利用する)
  func sync(_ block: () -> Void) {
    if DispatchQueue.getSpecific(key: queueKey) != nil
      || OperationQueue.current === queue
    {
      block()
      return
    }
    dispatchQueue.sync(execute: block)
  }

  /// イベントを処理し、状態を更新する。queue 上で呼び出すこと。
  @discardableResult
  func handle(_ event: SignalingEvent) -> [SignalingEffect] {
    let oldPhase = state.phase
    let (newState, effects) = SignalingStateReducer.reduce(state: state, event: event)
    state = newState
    if oldPhase != state.phase {
      Logger.trace(
        type: .signalingChannel,
        message:
          "changed state from \(oldPhase.connectionState) to \(state.phase.connectionState)")
    }
    if effects.contains(.publishSnapshot) {
      publishSnapshot()
    }
    return effects
  }

  /// 現在の状態。queue 上でのみ読むこと。
  var currentState: SignalingState {
    state
  }

  /// 現在使用中の WebSocket。queue 上でのみ読むこと。
  func currentChannelOnQueue() -> URLSessionWebSocketChannel? {
    currentChannel
  }

  /// 現在使用中の WebSocket を設定する。queue 上で呼び出すこと。
  func setCurrentChannel(_ channel: URLSessionWebSocketChannel?) {
    currentChannel = channel
    publishSnapshot()
  }

  /// 接続候補を追加する。queue 上で呼び出すこと。
  func addCandidate(_ channel: URLSessionWebSocketChannel) {
    candidates.append(channel)
  }

  /// 接続候補を取り除く。queue 上で呼び出すこと。
  func removeCandidate(_ channel: URLSessionWebSocketChannel) {
    candidates.removeAll { $0 === channel }
  }

  /// 接続候補の一覧。queue 上でのみ読むこと。
  func candidatesOnQueue() -> [URLSessionWebSocketChannel] {
    candidates
  }

  /// 接続候補をすべて取り除く。queue 上で呼び出すこと。
  func clearCandidates() {
    candidates.removeAll()
  }

  /// 接続完了 handler を設定する。queue 上で呼び出すこと。
  func setOnConnect(_ handler: ((Error?) -> Void)?) {
    onConnect = handler
  }

  /// 接続完了 handler を取り出す (take-and-clear)。queue 上で呼び出すこと。
  func takeOnConnect() -> ((Error?) -> Void)? {
    let handler = onConnect
    onConnect = nil
    return handler
  }

  /// 同期 getter 用の snapshot。
  var snapshot: SignalingSnapshot {
    snapshotStorage.current()
  }

  /// 指定された識別子の WebSocket が現在使用中のものである場合に切断する。
  ///
  /// redirect などで WebSocket が切り替わっている場合は何もしない。
  func disconnectChannel(identifier: ObjectIdentifier) {
    sync {
      guard let channel = currentChannel,
        ObjectIdentifier(channel) == identifier
      else {
        return
      }
      channel.disconnect(error: nil)
    }
  }

  private func publishSnapshot() {
    snapshotStorage.publish(
      snapshot: SignalingSnapshot(
        state: state,
        currentChannelIdentifier: currentChannel.map(ObjectIdentifier.init)))
  }
}

/// 同期 getter が読むスナップショット。
struct SignalingSnapshot: Sendable {
  let state: SignalingState
  let currentChannelIdentifier: ObjectIdentifier?
}

/// 同期 getter が読む lock-backed snapshot storage。
final class SignalingSnapshotStorage {
  private let lock = NSLock()
  private var snapshot = SignalingSnapshot(
    state: SignalingState(), currentChannelIdentifier: nil)

  /// 現在の snapshot を返す。
  func current() -> SignalingSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return snapshot
  }

  /// snapshot を更新する。
  func publish(snapshot: SignalingSnapshot) {
    lock.lock()
    defer { lock.unlock() }
    self.snapshot = snapshot
  }
}
