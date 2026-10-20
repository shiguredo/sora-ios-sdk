import Foundation

/// PeerChannel の接続ライフサイクル状態。
///
/// PeerChannel の接続状態フラグ 5 つ (webSocketDisconnectScheduled /
/// disconnectTimerScheduled / disconnectTimerGeneration / transportEpoch /
/// isRedirecting) と、接続ライフサイクルの排他が扱う接続試行状態
/// (asyncOperationCount / isDisconnecting / isStartingConnection) を保持する。
/// あわせて、音声入力の初期化済みフラグ (isAudioInputInitialized) を接続試行状態と
/// 同じ扱いで保持する。状態は単一所有者である `ConnectionStateOwner` が所有する。
/// 接続状態フラグ 5 つは NSLock で保護された snapshot storage を通じて他のスレッドからも
/// 観測できるが、接続試行状態と isAudioInputInitialized の更新だけでは snapshot を
/// publish せず、所有者の直列 queue 上でのみ読む (同期 getter を持たない)。
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

  /// redirect 中であることを示すフラグ。
  ///
  /// `PeerChannel.isRedirecting` に対応する。redirect 中は旧 PeerConnection の
  /// 遅延通知を無視し、切断処理の続行判定にも使う。
  var isRedirecting: Bool = false

  /// 進行中の非同期処理数。
  ///
  /// 非同期処理の開始時に +1 し、終了時に -1 する。接続開始の初期ロック
  /// (`ConnectionStateOwner.beginConnectionStart`) も非同期処理としてこの数に含む。
  /// 初期ロックを別に数えないのは、旧 `Lock` が 1 つの数で「初期ロック + 進行中の非同期処理」を
  /// 管理しており、切断要求を遅延させる判断 (`asyncOperationCount == 0` か
  /// 接続試行中の `== 1` か) を同じ数で行っていたためである。代表的な増減の呼び出し元は
  /// `beginConnectionStart` (`+1`) と `beginAsyncOperation` (`+1`)、
  /// `endAsyncOperation` (`-1`)、および接続開始が失敗する `sendConnectMessage(error:)`
  /// (初期ロックを `-1`) である。非同期処理が 0 件になった時点で、
  /// 遅延保存された切断要求を実行する。
  var asyncOperationCount: Int = 0

  /// 切断処理が開始されたことを示すフラグ。
  ///
  /// `true` の間は新しい非同期処理を開始せず (`beginConnectionStart` /
  /// `beginAsyncOperation` が拒否する)、追加の切断要求も無視する。
  ///
  /// 「`isDisconnecting == true` ならば `asyncOperationCount == 0`」は不変条件ではない。
  /// 切断要求を受理した時点で進行中の非同期処理があれば、その数は 0 にならない。
  /// `requestDisconnect` が初期ロックを強制的に解放して 0 にするのは残高が 1 のときだけで、
  /// 残高が 2 以上のときは要求を保存するだけで残高を変えない。
  /// 到達可能な状態で成り立つのは、次の 2 つを前提にした呼び出し側の契約である。
  ///
  /// - `isDisconnecting` を立てるのは、非同期処理数の残高を 0 にする (0 件のとき)、
  ///   または接続開始の初期ロックを強制的に解放する (`asyncOperationCount == 1` かつ
  ///   接続完了 callback を保持しているとき) 場合に限る。後者では旧 `Lock` と同じく
  ///   `asyncOperationCount` を 0 にする
  /// - `isDisconnecting` が `true` の間に非同期処理が完了しても、`endAsyncOperation` は
  ///   非同期処理数を減らさず、遅延させた切断要求も実行しない。`isDisconnecting` を
  ///   立てた時点で残っていた非同期処理は、`basicDisconnect` の後始末へ進むだけで
  ///   残高を戻さない
  var isDisconnecting: Bool = false

  /// 接続開始の初期ロックを取得してから signaling の開始を確定するまでの区間を示すフラグ。
  ///
  /// 区間中に到着した切断要求は signaling を開始せずに実行するか、
  /// 開始の復帰後に実行するため `ConnectionStateOwner` へ保存する。
  var isStartingConnection: Bool = false

  /// 音声入力 (`RTCAudioSession.initializeInput`) の初期化が成功したか管理するフラグ。
  ///
  /// 削除前の `PeerChannel.isAudioInputInitialized` に対応する。読み書きは単一所有者である
  /// `ConnectionStateOwner` の直列 queue 上でだけ行う。接続状態フラグ 5 つとは異なり、
  /// このフラグの更新だけでは snapshot を publish しない (別のイベントが publish する際は
  /// state 全体の写しとして一緒に写る)。別スレッドの同期 getter から観測する必要が
  /// 無く、`ConnectionEffect.publishSnapshot` を返すイベントを増やすと `ConnectionEvent` の
  /// 追加時に publish の要否が曖昧になるためである。読みは所有者の同期 API
  /// (`ConnectionStateOwner.isAudioInputInitialized()`) から行う。
  ///
  /// check-then-act の原子性は持たない。`PeerChannel.initializeAudioInput()` の
  /// 「初期化済みなら何もしない」判定と、成功時の書き込みは別の区間であり、
  /// 同時に 2 回呼ばれた場合は両方が初期化処理へ進み得る。この原子性は変更前から
  /// 無いため、ここでは 1 回保証を設けない。
  var isAudioInputInitialized: Bool = false
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

  /// 接続開始の初期ロックを取得した (非同期処理数を +1 し、開始区間へ入る)
  case connectionStartBegan

  /// signaling の開始区間を正常に閉じた (開始区間フラグを解除する)
  case signalingStartFinished

  /// 保存された切断要求により signaling の開始を取り消した
  /// (非同期処理数を 0 にし、開始区間フラグを解除し、切断処理を開始する)
  case signalingStartCancelled

  /// 非同期処理の開始を登録した (非同期処理数を +1)
  case asyncOperationBegan

  /// 非同期処理の終了を登録した (非同期処理数を -1)
  case asyncOperationEnded

  /// 切断要求を受理した (切断処理を開始する)
  case disconnectAccepted

  /// 接続試行中に切断要求を受理した
  /// (初期ロックを解放し、非同期処理数を 0 にして切断処理を開始する)
  case disconnectAcceptedWhileConnecting

  /// 音声入力の初期化が成功した (初期化済みフラグを立てる)
  case audioInputInitialized
}

/// reducer が返す副作用。
///
/// reducer は副作用を直接実行せず、Effect として返す。
/// 接続状態フラグを変える 7 つのイベント (redirect / WebSocket 切断スケジュール /
/// 猶予タイマー / 切断完了) は snapshot を publish する。接続ライフサイクルの排他が
/// 扱うイベント (接続開始 / signaling 開始区間 / 非同期処理数 / 切断受理) と
/// 音声入力の初期化完了は publish の契機にしない。
/// これらは同期 getter から観測する必要が無い (`PeerChannel` は snapshot storage の
/// getter を 5 つの接続状態フラグにしか持たず、接続試行状態と音声入力の初期化済みフラグは
/// owner が直接読む) ため、
/// NSLock の取得を増やさない。
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
  /// 接続ライフサイクルの排他が扱うイベントは副作用を返さない。副作用を返さない
  /// イベントの state 遷移は、`ConnectionStateOwner` が同じ直列 queue 上で
  /// 直接読む (snapshot へは publish しない)。
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

    // 接続開始: 初期ロックを非同期処理数へ数え、開始区間へ入る。
    // (取得可否の判定は呼び出し側が同じ排他区間で行う)
    case .connectionStartBegan:
      state.asyncOperationCount += 1
      state.isStartingConnection = true

    // signaling 開始区間の正常終了: 開始区間フラグだけを解除する。
    // (初期ロックは接続の終端まで保持する)
    case .signalingStartFinished:
      state.isStartingConnection = false

    // signaling 開始の取消: 保存された切断要求を実行するため、
    // 初期ロックを解放し、開始区間フラグを解除し、切断処理を開始する。
    case .signalingStartCancelled:
      state.asyncOperationCount = 0
      state.isStartingConnection = false
      state.isDisconnecting = true

    // 非同期処理の開始: 進行中の非同期処理数を増やす。
    case .asyncOperationBegan:
      state.asyncOperationCount += 1

    // 非同期処理の終了: 進行中の非同期処理数を減らす。
    // (0 になった後の切断要求の実行可否は呼び出し側が判定する)
    case .asyncOperationEnded:
      state.asyncOperationCount -= 1

    // 切断要求の受理: 新しい非同期処理の開始と追加の切断要求を止める。
    case .disconnectAccepted:
      state.isDisconnecting = true

    // 接続試行中の切断要求の受理: 初期ロックを解放して切断処理を開始する。
    // (この経路を通らないと初期ロックが解放されず basicDisconnect へ到達しない)
    case .disconnectAcceptedWhileConnecting:
      state.asyncOperationCount = 0
      state.isDisconnecting = true

    // 音声入力の初期化完了: 初期化済みフラグを立てる。
    // (接続試行状態と同じく同期 getter を持たない値であるため、このイベントでは
    //  snapshot を publish しない)
    case .audioInputInitialized:
      state.isAudioInputInitialized = true
    }

    return (state, effects)
  }
}

/// 遅延実行する切断要求。
///
/// 進行中の非同期処理が完了するまで実行できない切断要求を保持する。
/// `ConnectionStateOwner` の直列 queue 上でのみ読み書きする。
struct PendingDisconnect {
  /// 切断の原因となったエラー
  let error: (any Error)?

  /// 切断の理由
  let reason: DisconnectReason
}

/// signaling 開始の判定結果。
///
/// `ConnectionStateOwner.prepareSignalingStart` が、開始前の切断要求を踏まえて
/// 呼び出し側が取るべき行動を返す。
enum SignalingStartDecision {
  /// signaling の開始を許可する
  case start

  /// 既に切断処理が開始されているため何もしない
  case ignored

  /// 保存された切断要求を実行する
  case disconnect(PendingDisconnect)
}

/// PeerChannel の接続状態フラグの単一所有者。
///
/// reducer と接続に属する mutable state を所有し、直列化された ingress を通じて
/// イベントを直列に処理する。state の更新はいつもこの所有者の上で行われる。
///
/// 接続ライフサイクルの排他 (接続開始の初期ロック、進行中の非同期処理数、
/// 遅延させる切断要求) もこの所有者が同じ直列 queue で担う。同期 API から
/// await で呼び出さずに済むよう、actor ではなく `DispatchQueue` (serial)
/// による直列化を採用している。
final class ConnectionStateOwner: @unchecked Sendable {
  /// イベントを直列処理するための serial DispatchQueue。
  /// 複数のスレッドから `handle` や接続ライフサイクルの各 API が呼ばれても、
  /// この queue 上で直列化される。
  private let eventQueue = DispatchQueue(
    label: "jp.shiguredo.sora.ConnectionStateOwner")

  /// 現在の reducer state。`eventQueue` 上の直列処理でのみ読み書きする。
  private var currentState: ConnectionLifecycleState

  /// 進行中の非同期処理が終わるまで遅延させる切断要求。
  /// `eventQueue` 上の直列処理でのみ読み書きする。
  private var pendingDisconnect: PendingDisconnect?

  /// snapshot storage。同期 getter が読み、NSLock で保護される。
  private let snapshotStorage: ConnectionSnapshotStorage

  /// snapshotStorage は必須引数とする。既定値で内部生成すると、呼び出し元が読む
  /// storage と別の instance になり、publish した snapshot が誰にも観測されなくなる。
  init(snapshotStorage: ConnectionSnapshotStorage) {
    self.currentState = ConnectionLifecycleState()
    self.snapshotStorage = snapshotStorage
  }

  /// 現在の reducer state を更新し、必要な副作用を実行する。
  ///
  /// イベントは serial queue 上で直列に処理され、順序が確定する。副作用は
  /// `applyEvent` が実行するため戻り値は返さない (effect を呼び出し側で実行する
  /// 用途が生じた場合は、`applyEvent` の戻り値をそのまま返す形に戻す)。
  func handle(_ event: ConnectionEvent) {
    eventQueue.sync {
      applyEvent(event)
    }
  }

  /// 現在の接続試行状態を返す。
  ///
  /// 同期 getter から観測する必要が無い接続試行状態を、テストが owner の同期 API と
  /// 組み合わせて検証するために公開する。接続状態フラグは snapshot storage から読む。
  func stateForTesting() -> ConnectionLifecycleState {
    eventQueue.sync {
      currentState
    }
  }

  /// 音声入力の初期化が完了しているかを返す。
  ///
  /// `stateForTesting()` と同じく、単一所有者の直列 queue へ同期 wait して読む。
  /// `isAudioInputInitialized` の更新だけでは snapshot storage へ publish しないため、
  /// 本番コードからこの値を観測できるのはこの API だけである (テストは
  /// `stateForTesting()` でも観測できる)。
  ///
  /// この読み取り API を、owner の排他区間で呼ばれる closure
  /// (`shouldCancelDisconnectTimerBasedDisconnect` / `isConnectHandlerHeld`) から呼ばないこと。
  /// 直列 queue は再入できないため、排他区間から呼ぶと deadlock する。
  /// `isAudioInputInitialized` は切断判定から読まないため、この制約には触れない。
  func isAudioInputInitialized() -> Bool {
    eventQueue.sync {
      currentState.isAudioInputInitialized
    }
  }

  // MARK: - 接続ライフサイクルの排他

  /// 接続開始の初期ロックを取得します。
  ///
  /// 切断処理が開始済み、または既に接続開始区間にある場合は取得しません。
  /// 取得できた場合は非同期処理数を +1 し、開始区間へ入ります。
  @discardableResult
  func beginConnectionStart() -> Bool {
    var accepted = false
    eventQueue.sync {
      guard !currentState.isDisconnecting, !currentState.isStartingConnection else {
        return
      }
      applyEvent(.connectionStartBegan)
      accepted = true
    }
    return accepted
  }

  /// signaling の開始を、開始前に到着した切断要求と直列化します。
  ///
  /// 開始前に保存された切断要求がある場合は、接続の回復により取り消すか、
  /// 実行するかを確定します。取り消す場合は開始を許可し、
  /// 実行する場合は初期ロックを解放して切断要求を返します。
  ///
  /// - Parameter shouldCancelDisconnectTimerBasedDisconnect:
  ///   保存された切断要求を取り消すかを判定する closure。この関数の排他区間内で、
  ///   対象の要求が存在するときにだけ呼びます。
  func prepareSignalingStart(
    shouldCancelDisconnectTimerBasedDisconnect: (DisconnectReason) -> Bool
  ) -> SignalingStartDecision {
    var decision = SignalingStartDecision.ignored
    eventQueue.sync {
      guard !currentState.isDisconnecting else {
        return
      }
      if let pending = resolvePendingDisconnect(
        acceptedEvent: .signalingStartCancelled,
        shouldCancelDisconnectTimerBasedDisconnect:
          shouldCancelDisconnectTimerBasedDisconnect)
      {
        // 開始前の切断要求を実行する。初期ロックを解放し、開始区間も閉じる。
        decision = .disconnect(pending)
      } else {
        decision = .start
      }
    }
    return decision
  }

  /// signaling の開始区間を閉じ、その間に到着した切断要求を確定します。
  ///
  /// 開始区間の終了は常に反映します。実行すべき切断要求がある場合はそれを返します。
  ///
  /// - Parameter shouldCancelDisconnectTimerBasedDisconnect:
  ///   保存された切断要求を取り消すかを判定する closure。この関数の排他区間内で、
  ///   対象の要求が存在するときにだけ呼びます。
  func finishSignalingStart(
    shouldCancelDisconnectTimerBasedDisconnect: (DisconnectReason) -> Bool
  ) -> PendingDisconnect? {
    var immediate: PendingDisconnect?
    eventQueue.sync {
      // 開始区間の終了は、切断要求の有無にかかわらず常に反映する。
      applyEvent(.signalingStartFinished)
      guard !currentState.isDisconnecting else {
        return
      }
      immediate = resolvePendingDisconnect(
        acceptedEvent: .signalingStartCancelled,
        shouldCancelDisconnectTimerBasedDisconnect:
          shouldCancelDisconnectTimerBasedDisconnect)
    }
    return immediate
  }

  /// 進行中の非同期処理の開始を登録します。
  ///
  /// 切断処理が開始済みの場合は登録せず、呼び出し側は処理を開始しません。
  @discardableResult
  func beginAsyncOperation() -> Bool {
    var accepted = false
    eventQueue.sync {
      guard !currentState.isDisconnecting else {
        return
      }
      applyEvent(.asyncOperationBegan)
      accepted = true
    }
    return accepted
  }

  /// 進行中の非同期処理の終了を登録し、実行すべき切断要求を返します。
  ///
  /// 切断処理の開始後に完了した非同期処理の終了は無視します。非同期処理数が
  /// 0 になった場合に加えて、接続試行中 (非同期処理数が 1) に切断要求が保存されて
  /// いる場合も、ここで実行対象として取り出します。取り出した要求は
  /// 呼び出し側が排他区間の外で実行します。
  ///
  /// - Parameter shouldCancelDisconnectTimerBasedDisconnect:
  ///   保存された切断要求を取り消すかを判定する closure。この関数の排他区間内で、
  ///   対象の要求が存在するときにだけ呼びます。
  func endAsyncOperation(
    shouldCancelDisconnectTimerBasedDisconnect: (DisconnectReason) -> Bool
  ) -> PendingDisconnect? {
    var immediate: PendingDisconnect?
    eventQueue.sync {
      if currentState.isDisconnecting {
        // 切断処理の開始後に非同期処理が完了した場合の終了は無視する。
        // requestDisconnect は接続試行中の切断要求を切断処理へ直接到達させるため、
        // 後続の非同期処理が終了を登録しても非同期処理数は 0 のままである。
        return
      }
      // 残高の破綻を、残高を減らす前に検出する。旧 `Lock.unlock()` は
      // `isDisconnecting` の場合に減算せずに戻っていたため、破綻の検出は
      // 「切断処理が開始されていないとき」に限られていた。ここでも同じ範囲で検出する
      // (`isDisconnecting` の分岐を先に置く理由)。到達可能な状態では、対応する
      // `beginConnectionStart` / `beginAsyncOperation` が必ず 1 回成功しているため、
      // この分岐へは入らない。
      if currentState.asyncOperationCount <= 0 {
        assertionFailure("asyncOperationCount is already 0")
        return
      }
      applyEvent(.asyncOperationEnded)

      // 非同期処理数が 0 になった場合に加えて、接続試行中 (非同期処理数が 1) に
      // 切断要求があった場合も、進行中の非同期処理が完了したここで実行する。
      // これがないと、 createAndSendAnswer 実行中の切断要求が保存されたまま
      // 初期ロックが解放されず、 basicDisconnect が呼ばれない。
      guard
        currentState.asyncOperationCount == 0
          || (currentState.asyncOperationCount == 1 && pendingDisconnect != nil)
      else {
        return
      }
      guard pendingDisconnect != nil else {
        return
      }
      // 残高が 0 になった場合は、保存されていれば必ず実行する。
      immediate = resolvePendingDisconnect(
        acceptedEvent: .disconnectAcceptedWhileConnecting,
        shouldCancelDisconnectTimerBasedDisconnect:
          shouldCancelDisconnectTimerBasedDisconnect)
    }
    return immediate
  }

  /// 切断要求を受理します。
  ///
  /// 即時実行できない場合は保存し、進行中の非同期処理の終了時に実行します。
  /// 即時実行すべき場合はその要求を返し、呼び出し側が排他区間の外で実行します。
  ///
  /// - Parameter shouldCancelDisconnectTimerBasedDisconnect:
  ///   猶予タイマー由来の切断要求を取り消すかを判定する closure。この関数の
  ///   排他区間内で、対象の要求が存在するときにだけ呼びます。
  /// - Parameter isConnectHandlerHeld:
  ///   接続完了 callback を保持しているかを返す closure。接続試行中かどうかの
  ///   判定に使うため、この関数の排他区間内で呼びます。
  func requestDisconnect(
    error: (any Error)?,
    reason: DisconnectReason,
    shouldCancelDisconnectTimerBasedDisconnect: (DisconnectReason) -> Bool,
    isConnectHandlerHeld: () -> Bool
  ) -> PendingDisconnect? {
    var immediate: PendingDisconnect?
    eventQueue.sync {
      if currentState.isDisconnecting {
        // 切断処理が既に開始されている場合、追加の切断要求は無視する。
        return
      }
      if currentState.isStartingConnection {
        // signaling の開始可否を確定する前の切断要求は保存する。
        // startConnection が開始前に検出した場合は signaling を開始せずに切断する。
        pendingDisconnect = PendingDisconnect(error: error, reason: reason)
        return
      }
      if currentState.asyncOperationCount == 0 {
        // 猶予タイマー由来の切断要求は、タイマー発火時点の確認からここまでの間に
        // 接続が回復している場合は切断しない。
        if !shouldCancelDisconnectTimerBasedDisconnect(reason) {
          applyEvent(.disconnectAccepted)
          immediate = PendingDisconnect(error: error, reason: reason)
        }
        return
      }
      if currentState.asyncOperationCount == 1, isConnectHandlerHeld() {
        // 接続試行中 (接続開始の初期ロックのみが残っている状態) の切断要求。
        // 初期ロックは finishConnecting() か sendConnectMessage(error:) でのみ解放されるため、
        // answer 送信後の接続失敗などではそのまま解放されず basicDisconnect が呼ばれない。
        // その結果 RTCPeerConnection がクローズされずに残り続けるため、
        // ここで初期ロックを解放して切断処理を開始する。
        applyEvent(.disconnectAcceptedWhileConnecting)
        immediate = PendingDisconnect(error: error, reason: reason)
        return
      }
      // 進行中の非同期処理が完了するまで切断要求を遅延保存する。
      // 保存済みの切断要求は最後の切断要求で上書きされる。猶予タイマー由来の
      // 切断要求がその後の .failed 遷移の切断要求で上書きされると NO-ERROR 送信が
      // 失われるが (sendDisconnectMessageIfNeeded の state == .failed ガード)、
      // .failed は ICE の完全失敗であり送信が届く可能性が低いため妥当とする。
      pendingDisconnect = PendingDisconnect(error: error, reason: reason)
    }
    return immediate
  }

  /// 保存された切断要求を確定します。
  ///
  /// 呼び出し元は `eventQueue` 上で、`isDisconnecting` を確認した後に呼ぶこと。
  /// 猶予タイマー由来の切断要求が接続の回復により取り消される場合は、保存を破棄して
  /// nil を返す (切断処理は開始しない)。実行する場合は保存を破棄し、`acceptedEvent` を
  /// 適用してから、実行する要求を返す。保存が無い場合も nil を返す。
  ///
  /// 呼び出し元は戻り値の nil を「取り消し」と「保存なし」の両方に使う。どちらも
  /// signaling の開始を許可するか、切断を実行しない点で同じ扱いになる。
  ///
  /// - Parameters:
  ///   - acceptedEvent: 切断要求の受理として適用するイベント。signaling 開始の取消は
  ///     `.signalingStartCancelled`、接続試行中の受理は
  ///     `.disconnectAcceptedWhileConnecting` を使う。どちらも `asyncOperationCount` を
  ///     0 にして `isDisconnecting` を立てるが、接続開始区間の解除は前者だけが必要とする。
  ///   - shouldCancelDisconnectTimerBasedDisconnect:
  ///     保存された切断要求を取り消すかを判定する closure。対象の要求が存在するときに
  ///     だけ呼ぶ。
  private func resolvePendingDisconnect(
    acceptedEvent: ConnectionEvent,
    shouldCancelDisconnectTimerBasedDisconnect: (DisconnectReason) -> Bool
  ) -> PendingDisconnect? {
    guard let pending = pendingDisconnect else {
      return nil
    }
    // 接続が回復している場合は切断を取り消し、保存だけを破棄する。切断処理は開始しない
    // (開始すると以後の切断・再ネゴシエーションがすべて不能になるため。
    // 取り消し後は再び .disconnected になればタイマーが再開始される)。
    if shouldCancelDisconnectTimerBasedDisconnect(pending.reason) {
      pendingDisconnect = nil
      return nil
    }
    pendingDisconnect = nil
    applyEvent(acceptedEvent)
    return pending
  }

  /// 現在の state にイベントを適用し、副作用を実行します。
  ///
  /// 呼び出し元は `eventQueue` 上にいること。`handle(_:)` と接続ライフサイクルの
  /// 各 API が同じ経路を使う。
  private func applyEvent(_ event: ConnectionEvent) {
    let (newState, effects) = ConnectionStateReducer.reduce(
      state: currentState, event: event)
    currentState = newState

    publishSnapshot(effects: effects)
  }

  /// effect に publishSnapshot が含まれる場合だけ snapshot を更新する。
  ///
  /// publish する state は `applyEvent` が確定した `currentState` である。
  private func publishSnapshot(effects: [ConnectionEffect]) {
    if effects.contains(.publishSnapshot) {
      snapshotStorage.publish(state: currentState)
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
