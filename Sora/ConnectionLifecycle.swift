import Foundation

/// PeerChannel の接続状態フラグ reducer の状態。
///
/// PeerChannel の接続状態フラグ 5 つ (webSocketDisconnectScheduled /
/// disconnectTimerScheduled / disconnectTimerGeneration / transportEpoch /
/// isRedirecting) を保持する。状態は単一所有者である `ConnectionStateOwner` が所有し、
/// その他のスレッドは NSLock で保護された snapshot storage を通じてのみ観測する。
struct ConnectionLifecycleState: Sendable {
  /// transport 世代。接続の transport が変わるたびに増加する。
  ///
  /// `dataChannelGeneration` に対応する。redirect で transport が変わる際に +1 される。
  /// DataChannel delegate の遅延通知拒否 (世代照合) に利用する。
  var transportEpoch: Int = 0

  /// WebSocket の切断がスケジューリングされているか管理するフラグ。
  ///
  /// `PeerChannel.webSocketDisconnectScheduled` に対応する。
  /// DataChannel シグナリング切り替え後の WebSocket の二重切断を防ぐ。
  var webSocketDisconnectScheduled: Bool = false

  /// 切断検出の猶予タイマーが開始されているか管理するフラグ。接続完了後のみ動作する。
  ///
  /// 猶予タイマーは、接続完了後に `RTCPeerConnectionState` が `.disconnected` へ
  /// 遷移してから切断するまでの様子見時間 (猶予) を計るタイマー。
  /// 一時的なネットワーク切断 (`.disconnected` → `.connected` の回復) を
  /// 阻害しないために設ける。タイマーの期間中に接続が回復した場合は
  /// 切断しない (回復を阻害しない)。
  ///
  /// `PeerChannel.disconnectTimerScheduled` に対応する。
  /// 待機タイマーの二重開始を防ぐ。
  var disconnectTimerScheduled: Bool = false

  /// 猶予タイマーの世代。
  ///
  /// `PeerChannel.disconnectTimerGeneration` に対応する。
  /// タイマー発火時に世代が一致しないと無視される (キャンセル済みタイマーの遅延発火対策)。
  var disconnectTimerGeneration: Int = 0

  /// redirect が発生したことを示すフラグ。redirect に応答して旧 transport は無効化される。
  ///
  /// `PeerChannel.isRedirecting` に対応する。redirect 中は旧 PeerConnection の
  /// 遅延通知を無視し、切断処理の続行判定にも使う。
  var isRedirecting: Bool = false
}

/// PeerChannel の接続状態フラグを駆動するイベント。
///
/// `ConnectionStateOwner` の `handle(_:)` へ入力する。
/// 状態遷移に必要な事実のみを運ぶ。
enum ConnectionEvent: Sendable {
  /// WebSocket 切断スケジュールに登録した
  case webSocketDisconnectScheduled

  /// 切断猶予タイマー開始
  case disconnectTimerScheduled

  /// 切断猶予タイマー発火
  case disconnectTimerFired

  /// 切断猶予タイマーキャンセル
  case disconnectTimerCancelled

  /// redirect 受信 (旧 transport の無効化)
  case redirectReceived

  /// redirect 窓の終了 (新 PC 生成)
  case redirectConnectStarted

  /// 切断完了 (基本切断)
  case disconnectCompleted
}

/// reducer が返す副作用。
///
/// reducer は副作用を直接実行せず、Effect として返す。
/// 現在は publishSnapshot のみである (全イベントが無条件に publish する)。
/// 将来、Sendable event API で効果 (callback 配送等) を追加する際は、
/// この enum へケースを追加し、reducer が返す Effect を呼び出し側で実行する。
/// (イベント追加時に publishSnapshot の書き忘れがないよう、追加時は確認すること)
enum ConnectionEffect: Sendable {
  /// 状態の更新を snapshot に publish する
  case publishSnapshot
}

/// PeerChannel の接続状態フラグ reducer。
///
/// (State, Event) を入力として、次の State と副作用のリストを返す純粋関数。
/// イベントは呼び出し側のガードを通過したもののみが渡される。
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

    switch event {
    // redirect 受信: transport が変わるため世代を増加させ、来歴フラグを立てる。
    // (redirect 中も接続は継続されるため、フラグは true になる)
    case .redirectReceived:
      state.transportEpoch += 1
      state.isRedirecting = true
      effects.append(.publishSnapshot)

    // redirect 窓の終了 (新 PC 生成): isRedirecting を解除し、
    // リダイレクト窓でスキップされた WebSocket 切断スケジュールをリセットする。
    // (新接続でも同じスケジュールを再度実行できるようにする)
    case .redirectConnectStarted:
      state.isRedirecting = false
      state.webSocketDisconnectScheduled = false
      effects.append(.publishSnapshot)

    // WebSocket 切断スケジュール: スケジュール済みフラグを true にする。
    // 二重のスケジューリングは呼び出し側のガード (check-then-act) で防ぐ
    // (ベストエフォート。重複しても発火時ガードで無害化される)。
    case .webSocketDisconnectScheduled:
      state.webSocketDisconnectScheduled = true
      effects.append(.publishSnapshot)

    // 猶予タイマー開始: 開始済みフラグを true にし、現在の世代を保持する。
    // 二重開始は呼び出し側のガード (check-then-act) で防ぐ
    // (ベストエフォート。重複しても世代照合と状態再確認で無害化される)。
    case .disconnectTimerScheduled:
      state.disconnectTimerScheduled = true
      effects.append(.publishSnapshot)

    // 猶予タイマー発火: タイマーは 1 回だけ発火するため、開始済みフラグを
    // false に戻す。世代は変えない (発火したタイマーは以後使われない)。
    // (発火後は再び .disconnected になった場合に、次のタイマーを開始できる)
    case .disconnectTimerFired:
      state.disconnectTimerScheduled = false
      effects.append(.publishSnapshot)

    // 猶予タイマーキャンセル: 開始済みフラグを false にし、世代を +1 する。
    // (キャンセル済みタイマーの遅延発火は世代照合で無視する)
    case .disconnectTimerCancelled:
      state.disconnectTimerScheduled = false
      state.disconnectTimerGeneration += 1
      effects.append(.publishSnapshot)

    // 切断完了: リダイレクト中フラグと WebSocket 切断スケジュールをリセットする。
    // (切断によりリダイレクトは中止され、以降のフラグは初期状態に戻る)
    case .disconnectCompleted:
      state.isRedirecting = false
      state.webSocketDisconnectScheduled = false
      effects.append(.publishSnapshot)
    }

    return (state, effects)
  }
}

/// PeerChannel の接続状態フラグの単一所有者。
///
/// reducer と接続に属する mutable state を所有し、直列化された ingress を通じて
/// イベントを直列に処理する。state の更新はいつもこの所有者の上で行われる。
///
/// 同期 API から await で呼び出さずに済むよう、actor ではなく `DispatchQueue` (serial)
/// による直列化を採用している。
final class ConnectionStateOwner: @unchecked Sendable {
  /// イベントを直列処理するための serial DispatchQueue。
  /// 複数のスレッドから `handle` が呼ばれても、この queue 上で直列化される。
  private let eventQueue = DispatchQueue(
    label: "jp.shiguredo.sora.ConnectionStateOwner")

  /// 現在の reducer state。`eventQueue` 上の直列処理でのみ読み書きする。
  private var currentState: ConnectionLifecycleState

  /// snapshot storage。同期 getter が読み、NSLock で保護される。
  private let snapshotStorage: ConnectionSnapshotStorage

  init(snapshotStorage: ConnectionSnapshotStorage = ConnectionSnapshotStorage()) {
    self.currentState = ConnectionLifecycleState()
    self.snapshotStorage = snapshotStorage
  }

  /// 現在の reducer state を更新し、必要な副作用を返す。
  ///
  /// イベントは serial queue 上で直列に処理され、順序が確定する。
  @discardableResult
  func handle(_ event: ConnectionEvent) -> [ConnectionEffect] {
    eventQueue.sync {
      let (newState, effects) = ConnectionStateReducer.reduce(
        state: currentState, event: event)
      currentState = newState

      // state が変更された場合は snapshot を publish する。
      publishSnapshot(state: newState, effects: effects)

      return effects
    }
  }

  private func publishSnapshot(state: ConnectionLifecycleState, effects: [ConnectionEffect]) {
    if effects.contains(.publishSnapshot) {
      snapshotStorage.publish(state: state)
    }
  }
}

/// 同期 getter が読む lock-backed snapshot storage。
///
/// `PeerChannel` 等の同期 getter は単一所有者の同期 wait を行わず、
/// この storage を NSLock で読み込んで snapshot を返す。
final class ConnectionSnapshotStorage {
  private let lock = NSLock()
  private var snapshot: ConnectionLifecycleState

  init(state: ConnectionLifecycleState = ConnectionLifecycleState()) {
    self.snapshot = state
  }

  /// 現在の snapshot を返す。
  func current() -> ConnectionLifecycleState {
    lock.lock()
    defer { lock.unlock() }
    return snapshot
  }

  /// snapshot を更新する。
  func publish(state: ConnectionLifecycleState) {
    lock.lock()
    defer { lock.unlock() }
    snapshot = state
  }
}
