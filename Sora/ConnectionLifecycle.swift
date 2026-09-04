import Foundation

/// 接続ライフサイクルの phase を表します。
///
/// 利用者から観測される `MediaChannel.state` (`ConnectionState`) を置き換える。
/// `ConnectionState` との対応:
/// - `connecting` -> `.connecting`
/// - `connected` -> `.connected`
/// - `disconnecting` -> `.disconnecting`
/// - `disconnected` -> `.disconnected`
enum ConnectionPhase: Sendable {
  /// 接続試行中
  case connecting

  /// 接続成功済み
  case connected

  /// 接続解除試行中
  case disconnecting

  /// 接続解除済み
  case disconnected

  /// 公開 API の `ConnectionState` へ変換する。
  var connectionState: ConnectionState {
    switch self {
    case .connecting:
      return .connecting
    case .connected:
      return .connected
    case .disconnecting:
      return .disconnecting
    case .disconnected:
      return .disconnected
    }
  }
}

/// 接続ライフサイクル状態 reducer の State。
///
/// 接続 phase、論理接続 ID、transport epoch、配送済み callback 台帳を保持する。
/// State は single owner である `ConnectionStateOwner` (actor) が所有し、
/// その他のスレッドは `ConnectionSnapshot` を通じてのみ観測する。
struct ConnectionLifecycleState: Sendable {
  /// 接続 phase
  var phase: ConnectionPhase = .disconnected

  /// 論理接続 ID。接続ごとに一意な値を保持する。
  ///
  /// 接続の再試行や redirect を跨いでも同じ値を維持する。
  /// (この ID は、複数接続のイベントを識別するための内部 ID であり、
  /// `connectionId` (`type: offer` で Sora が払い出す ID) とは異なる)
  let logicalConnectionID: UUID

  /// transport epoch。接続の transport が変わるたびに増加する。
  ///
  /// `dataChannelGeneration` に対応する。redirect で transport が変わる際に +1 される。
  /// DataChannel delegate の遅延通知拒否 (世代照合) に利用する。
  var transportEpoch: Int = 0

  /// 配送済み callback 台帳。callback の過剰配送 (重複終端) を防ぐ。
  var deliveryTracker = DeliveryTracker()

  /// WebSocket の切断スケジュール済みフラグ。
  ///
  /// `PeerChannel.webSocketDisconnectScheduled` に対応する。
  /// DataChannel シグナリング切り替え後の WebSocket 切断の二度送りを防ぐ。
  var webSocketDisconnectScheduled: Bool = false

  /// 接続完了後の切断検出の猶予タイマーの開始済みフラグ。
  ///
  /// `PeerChannel.disconnectTimerScheduled` に対応する。
  /// 一時的なネットワーク切断を阻害しないための待機タイマーの二度開始を防ぐ。
  var disconnectTimerScheduled: Bool = false

  /// 猶予タイマーの世代。
  ///
  /// `PeerChannel.disconnectTimerGeneration` に対応する。
  /// タイマー発火時に世代が一致しないと無視される (キャンセル済みタイマーの遅延発火対策)。
  var disconnectTimerGeneration: Int = 0

  /// redirect に応答して旧 transport を無効化したフラグ。
  ///
  /// `PeerChannel.isRedirecting` に対応する。redirect 中は旧 PeerConnection の
  /// 遅延通知を無視し、切断処理の続行判定にも使う。
  var isRedirecting: Bool = false

  init(logicalConnectionID: UUID = UUID()) {
    self.logicalConnectionID = logicalConnectionID
  }
}

/// 配送済み callback 台帳。
///
/// 接続完了 callback (`onConnect`) などが 1 回だけ配送されることを保証する。
/// reducer の State として保持され、コールバックの配送状況を追跡する。
struct DeliveryTracker: Sendable {
  /// 接続完了 callback (`onConnect`) を配送済みかどうか
  ///
  /// PeerChannel の `onConnect` を取ってから呼び出す (take-and-clear)
  /// パターンを、reducer の State として排他的に管理する。
  private(set) var didDeliverConnect: Bool = false

  /// 接続完了 callback を配送したことを記録する。
  ///
  /// 既に配送済みの場合は `false` を返す (過剰配送を防ぐ)。
  @discardableResult
  mutating func markConnectDelivered() -> Bool {
    if didDeliverConnect {
      return false
    }
    didDeliverConnect = true
    return true
  }
}

/// 接続ライフサイクルを駆動するイベント。
///
/// `ConnectionStateOwner.Intake` へ yield する入力。
/// Signaling や SoraError などの型を含めず、状態遷移に必要な事実のみを運ぶ。
/// (生の型を含めると Sendable にできず、payload に含めると状態管理の
/// 責任が外部に漏れるためである)
enum ConnectionEvent: Sendable {
  /// 接続開始要求 (利用者操作)
  case connectRequested

  /// キャンセル要求 (利用者操作)
  case cancelRequested

  /// 切断要求 (利用者操作)
  case disconnectRequested(reason: DisconnectReason)

  /// WebSocket 接続成功 (`type: connect` を送信)
  case connectMessageSent

  /// offer 受信 (Sora から offer を受け取った)
  case offerReceived

  /// 接続完了 (PeerChannel が完成)
  case connectionEstablished

  /// 接続失敗
  case connectionFailed

  /// 接続タイムアウト
  case connectionTimeout

  /// redirect 要求 (Sora から redirect を受け取った)
  case redirectReceived

  /// redirect 先への接続開始 (新 transport)
  case redirectConnectStarted

  /// redirect 先への接続完了
  case redirectConnectEstablished

  /// WebSocket 切断スケジュール
  case webSocketDisconnectScheduled

  /// 切断猶予タイマー開始
  case disconnectTimerScheduled

  /// 切断猶予タイマー発火
  case disconnectTimerFired

  /// 切断猶予タイマーキャンセル
  case disconnectTimerCancelled

  /// 切断完了
  case disconnectCompleted
}

/// reducer が返す副作用。
///
/// reducer は副作用を直接実行せず、Effect として返す。
/// WebRTC 操作・callback 配送・snapshot 更新などが該当する。
enum ConnectionEffect: Sendable {
  /// 接続 phase の更新を snapshot に publish する
  case publishSnapshot

  /// 接続完了 callback を配送する
  case deliverConnectCallback

  /// 接続失敗 callback を配送する
  case deliverConnectCallbackWithError

  /// 切断通知を配送する
  case deliverDisconnect
}

/// 接続ライフサイクル状態 reducer。
///
/// (State, Event) を入力として、次の State と副作用のリストを返す純粋関数。
/// 不正な状態遷移や stale epoch のイベントを明示的に拒否する。
enum ConnectionStateReducer {
  /// イベントを処理し、次の State と副作用を返す。
  ///
  /// - Returns: 更新後の State と実行すべき Effect のリスト
  static func reduce(
    state: ConnectionLifecycleState,
    event: ConnectionEvent
  ) -> (state: ConnectionLifecycleState, effects: [ConnectionEffect]) {
    var state = state
    var effects: [ConnectionEffect] = []

    switch (state.phase, event) {
    // 接続開始: disconnected (または初期) からのみ受理
    case (.disconnected, .connectRequested):
      state.phase = .connecting
      effects.append(.publishSnapshot)

    case (.disconnecting, .connectRequested):
      // 切断中に connect を要求することは誤用である。明示的に拒否する。
      break

    // キャンセル要求: connecting 中のからのみ受理
    case (.connecting, .cancelRequested):
      state.phase = .disconnecting
      effects.append(.publishSnapshot)

    // 切断要求: connecting / connected からのみ受理
    case (.connecting, .disconnectRequested):
      state.phase = .disconnecting
      effects.append(.publishSnapshot)
    case (.connected, .disconnectRequested):
      state.phase = .disconnecting
      effects.append(.publishSnapshot)

    case (.disconnecting, .disconnectRequested):
      // 切断中に再び切断要求は無視する (既に切断処理中)
      break
    case (.disconnected, .disconnectRequested):
      break

    // offer 受信: connecting 中のみ
    case (.connecting, .offerReceived):
      state.transportEpoch += 1
      effects.append(.publishSnapshot)

    case (.connected, .offerReceived):
      // redirect 中の offer (新 transport) での epoch 更新のみ受け付ける
      state.transportEpoch += 1
      effects.append(.publishSnapshot)

    // 接続完了: connecting 中のみ
    case (.connecting, .connectionEstablished):
      state.phase = .connected
      effects.append(.publishSnapshot)
      if state.deliveryTracker.markConnectDelivered() {
        effects.append(.deliverConnectCallback)
      }

    case (.connecting, .connectionFailed):
      state.phase = .disconnected
      effects.append(.publishSnapshot)
      if state.deliveryTracker.markConnectDelivered() {
        effects.append(.deliverConnectCallbackWithError)
      }

    // 接続タイムアウト: connecting 中のみ
    case (.connecting, .connectionTimeout):
      state.phase = .disconnecting
      effects.append(.publishSnapshot)

    // redirect の受け付け: connecting / connected 中のみ。
    // どちらでも、transport が変わるため epoch を増加させる。
    // (redirect 中も接続は継続されるため、phase は変えない)
    case (.connecting, .redirectReceived):
      state.transportEpoch += 1
      state.isRedirecting = true
      effects.append(.publishSnapshot)
    case (.connected, .redirectReceived):
      state.transportEpoch += 1
      state.isRedirecting = true
      effects.append(.publishSnapshot)
    // redirect 窓の終了 (新 PC 生成): isRedirecting を解除し、
    // リダイレクト窓でスキップされた WebSocket 切断スケジュールをリセットする。
    // (新接続でも同じスケジュールを再度実行できるようにする)
    case (_, .redirectConnectStarted):
      state.isRedirecting = false
      state.webSocketDisconnectScheduled = false
      effects.append(.publishSnapshot)
    case (_, .redirectConnectEstablished):
      break

    // WebSocket 切断スケジュール: スケジュール済みフラグを true にする。
    // (二度目の schedule は拒否される。いわゆる 1 回だけのスケジュール)
    case (_, .webSocketDisconnectScheduled):
      state.webSocketDisconnectScheduled = true
      effects.append(.publishSnapshot)

    // 猶予タイマー開始: 開始済みフラグを true にし、現在の世代を保持する。
    // (二度目の開始は拒否される)
    case (_, .disconnectTimerScheduled):
      state.disconnectTimerScheduled = true
      effects.append(.publishSnapshot)

    // 猶予タイマー発火: タイマーは 1 回だけ発火するため、開始済みフラグを
    // false に戻す。世代は変えない (発火したタイマーは以後使われない)。
    // (発火後は再び .disconnected になった場合に、次のタイマーを開始できる)
    case (_, .disconnectTimerFired):
      state.disconnectTimerScheduled = false
      effects.append(.publishSnapshot)

    // 猶予タイマーキャンセル: 開始済みフラグを false にし、世代を +1 する。
    // (キャンセル済みタイマーの遅延発火は世代照合で無視する)
    case (_, .disconnectTimerCancelled):
      state.disconnectTimerScheduled = false
      state.disconnectTimerGeneration += 1
      effects.append(.publishSnapshot)

    // 切断完了: disconnecting から
    case (.disconnecting, .disconnectCompleted):
      state.phase = .disconnected
      // 切断によりリダイレクトは中止され、フラグは初期状態に戻る。
      state.isRedirecting = false
      state.webSocketDisconnectScheduled = false
      effects.append(.publishSnapshot)
      effects.append(.deliverDisconnect)

    default:
      // その他の不正な遷移は明示的に拒否する (何もしない)。
      break
    }

    return (state, effects)
  }
}

/// 接続ライフサイクルの single owner。
///
/// reducer と接続に属する mutable state を所有し、ordered ingress を通じて
/// イベントを直列に処理する。state の更新はいつもこの owner の上で行われる。
///
/// 同期 API (`connect` / `disconnect`) から await で呼び出さずに済むよう、
/// actor ではなく `DispatchQueue` (serial) による直列化を採用している。
/// (actor にすると同期メソッドの `state = .connecting` 等の書き込みが
/// `await` を必要とし、`internalDisconnect` の一連の流れが同期で保てなくなるため)
///
/// - Note: 同期 getter は owner の同期 wait を行わない (ロックされた
///   snapshot storage を参照する)。これは callback 内から同期 getter を
///   呼んでも deadlock しないための設計である。
final class ConnectionStateOwner: @unchecked Sendable {
  /// イベントを直列処理するための serial DispatchQueue。
  /// 利用者スレッド、WebSocket delegate、libwebrtc callback など
  /// 複数のスレッドから `handle` が呼ばれても、この queue 上で直列化される。
  private let eventQueue = DispatchQueue(
    label: "jp.shiguredo.sora.ConnectionStateOwner")

  /// 現在の reducer state。`eventQueue` 上の直列処理でのみ読み書きする。
  private var currentState: ConnectionLifecycleState

  /// snapshot storage。同期 getter が読み、NSLock で保護される。
  private let snapshotStorage: ConnectionSnapshotStorage

  init(
    logicalConnectionID: UUID = UUID(),
    snapshotStorage: ConnectionSnapshotStorage = ConnectionSnapshotStorage()
  ) {
    self.currentState = ConnectionLifecycleState(
      logicalConnectionID: logicalConnectionID)
    self.snapshotStorage = snapshotStorage
  }

  /// 現在の reducer state を更新し、必要な副作用を返す。
  ///
  /// 利用者操作・signaling event・PeerConnection event・DataChannel event、
  /// timeout、redirect、切断はすべてこの関数を経由する。
  /// イベントは serial queue 上で直列に処理され、順序が確定する。
  @discardableResult
  func handle(_ event: ConnectionEvent) -> [ConnectionEffect] {
    // 同期呼び出しからこの関数が呼ばれても、直列 queue の順序が保証され、
    // 結果として state の取り出しと publish が一貫した順序になる。
    eventQueue.sync {
      let (newState, effects) = ConnectionStateReducer.reduce(
        state: currentState, event: event)
      currentState = newState

      // phase 遷移時および transportEpoch 変更時に snapshot を publish する。
      // (snapshot は publish しっぱなしにならないよう、イベントごとに
      // 変更があった場合のみ更新する。将来は Effect の一覧に含める)
      publishSnapshot(state: newState, effects: effects)

      return effects
    }
  }

  /// 現在の reducer state を確認するための読み取り。
  ///
  /// 通常の読み取りは `snapshotStorage.current()` を使う。このメソッドは
  /// テストおよび状態の確定時に使う。
  func drainedState() -> ConnectionLifecycleState {
    eventQueue.sync { currentState }
  }

  private func publishSnapshot(state: ConnectionLifecycleState, effects: [ConnectionEffect]) {
    // publishSnapshot effect が含まれる場合のみ snapshot を更新する
    if effects.contains(.publishSnapshot) {
      snapshotStorage.publish(state: state)
    }
  }
}

/// 同期 getter のための snapshot です。
///
/// 接続状態の各 getter (`MediaChannel.state` 等) が、lock で保護された
/// この値から読む。immutable な値のコピーを保持する。
struct ConnectionStateSnapshot: Sendable {
  let state: ConnectionLifecycleState
}

/// 同期 getter が読む lock-backed snapshot storage。
///
/// `MediaChannel` 等の同期 getter は actor の同期 wait を行わず、
/// この storage を NSLock で読み込んで snapshot を返す。
final class ConnectionSnapshotStorage {
  private let lock = NSLock()
  private var snapshot: ConnectionStateSnapshot

  init(state: ConnectionLifecycleState = ConnectionLifecycleState()) {
    self.snapshot = ConnectionStateSnapshot(state: state)
  }

  /// 現在の snapshot を返す。
  func current() -> ConnectionStateSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return snapshot
  }

  /// snapshot を更新する。
  func publish(state: ConnectionLifecycleState) {
    lock.lock()
    snapshot = ConnectionStateSnapshot(state: state)
    lock.unlock()
  }
}
