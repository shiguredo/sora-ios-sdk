import Foundation

/// カメラ操作の対象となる `CameraVideoCapturer` instance を識別する ID です。
///
/// instance ごとに 1 つ発行します。`CameraVideoCapturer` 自身が採番し、
/// `CameraStateOwner` の instance テーブルへ登録します。
/// `CameraState` / `CameraEvent` へ値として渡せるよう `Sendable` に準拠します。
struct CameraCapturerID: Hashable, Sendable {
  private let value = UUID()
}

/// カメラの状態遷移を表す phase です。
///
/// 物理カメラはプロセスに 1 つしかないため、 phase も 1 つだけ持ちます。
/// 現在 production で読むのは `.quarantined` (隔離中は新しいカメラ操作を拒否する)
/// だけですが、状態機械の現在地を表す情報として保持します。
enum CameraPhase: Sendable, Equatable {
  /// カメラが停止している
  case idle

  /// カメラを開始している
  case starting

  /// カメラが動作している
  case running

  /// カメラを停止している
  case stopping

  /// カメラを切り替えている
  case flipping

  /// クリーンアップ失敗によりカメラを隔離している
  case quarantined
}

/// カメラ状態の reducer が扱う状態です。
///
/// `Sendable` な値だけで構成します。`AVCaptureDevice` / `AVCaptureDevice.Format` /
/// `RTCCameraVideoCapturer` / `MediaStream` などの non-Sendable な実資源は
/// `CameraStateOwner` の resource テーブルまたは capturer instance の lock 付き storage が
/// 保持し、この状態には含めません。
struct CameraState: Sendable {
  /// 現在動作中の capturer の ID
  ///
  /// native start が成功した時点で設定し、native stop が完了した時点で解除します。
  /// `CameraVideoCapturer.current` はこの ID だけを見て instance を解決します。
  var activeCapturerID: CameraCapturerID?

  /// カメラの phase
  var phase: CameraPhase = .idle

  /// capturer ごとに解決済みのフレームレート
  var frameRates: [CameraCapturerID: Int] = [:]

  /// 現在動作中の capturer の集合
  var runningCapturers: Set<CameraCapturerID> = []

  /// 切り替えが実行中か
  ///
  /// flip の re-entrance 判定に使います。`CameraVideoCapturer` の static フラグでは
  /// なく reducer の状態です。`CameraPhase.flipping` と違い、切り替えの完了イベントを
  /// 取りこぼした場合でも解除できます。
  ///
  /// 公開 `flip` は `CameraVideoCaptureCoordinator` が直列化するため、2 回目の flip は
  /// 前の flip の完了後に実行され、このフラグは通常 false です。coordinator を経由せず
  /// `flipForSDK` を呼ぶ経路の安全網として保持します。
  var isFlipping: Bool = false

  /// 操作の世代。操作の開始と隔離のたびに進み、古い callback の適用を防ぐ
  var operationGeneration: UInt64 = 0
}

/// カメラ状態を駆動するイベントです。
///
/// payload は `CameraCapturerID` / `UInt64` / `Int` / `Bool` などの値トークンに限定します。
/// `VideoHardMuteLease` / `CameraCaptureOwnership` などの参照型は owner の command 入力
/// (実行層) に留め、イベントには含めません。
enum CameraEvent: Sendable {
  /// カメラ開始の要求
  case startRequested(id: CameraCapturerID, generation: UInt64)

  /// format の解決完了。解決したフレームレートを状態へ反映する
  case formatResolved(id: CameraCapturerID, frameRate: Int, generation: UInt64)

  /// カメラ開始の完了
  case startCompleted(id: CameraCapturerID, generation: UInt64, success: Bool)

  /// カメラ停止の要求
  case stopRequested(id: CameraCapturerID, generation: UInt64)

  /// カメラ停止の完了
  ///
  /// native の停止は成否を返さない (`RTCCameraVideoCapturer.stopCapture` の完了ハンドラーは
  /// 成否を受け取らず、`AVCaptureSession` の停止にもエラー通知が無い) ため、開始の完了と
  /// 異なり `success` を持たず、完了通知が届いたことを停止成功として扱います。
  case stopCompleted(id: CameraCapturerID, generation: UInt64)

  /// カメラ再起動の要求 (内部で stop と start を実行する複合コマンド)
  case restartRequested(id: CameraCapturerID, generation: UInt64)

  /// カメラ再起動の完了
  case restartCompleted(id: CameraCapturerID, generation: UInt64, success: Bool)

  /// カメラ設定変更の要求 (内部で stop と start を実行する複合コマンド)
  case changeRequested(id: CameraCapturerID, generation: UInt64)

  /// カメラ設定変更の完了
  case changeCompleted(id: CameraCapturerID, generation: UInt64, success: Bool)

  /// カメラ切り替えの要求。切り替え先は command が解決して渡す
  case flipRequested(sourceID: CameraCapturerID, targetID: CameraCapturerID, generation: UInt64)

  /// カメラ切り替えの完了
  case flipCompleted(
    sourceID: CameraCapturerID, targetID: CameraCapturerID, generation: UInt64, success: Bool)

  /// クリーンアップ失敗による隔離
  case quarantined

  /// 隔離の解除
  case quarantineCleared

  /// capturer instance の解放 (deinit)。その ID の資源を state から破棄する
  case capturerReleased(id: CameraCapturerID)
}

/// reducer が返す副作用です。
///
/// reducer は副作用を直接実行せず、effect として返します。実行するのは owner
/// (`CameraStateOwner`) です。現在は publishSnapshot のみです (状態を変更する
/// 全イベントが publish します)。native の開始 / 停止は `CameraVideoCapturer` が
/// 直接実行し、completion と handler の呼び出しは実行側が自分の入力と対応付けて
/// owner の critical section 外で行います。
/// 将来 effect を追加する場合は、この enum へケースを追加し、owner で実行します。
/// (イベント追加時に publishSnapshot の書き忘れがないよう、追加時は確認すること)
enum CameraEffect: Sendable, Equatable {
  /// 状態の更新を snapshot に publish する
  case publishSnapshot
}

/// カメラ状態の reducer です。
///
/// (State, Event) を入力として、次の State と副作用のリストを返す純粋関数です。
/// イベントは呼び出し側のガードを通過したもののみが渡されます。
/// generation の照合は reducer で行い、一致しないイベントは状態を変えずに無視します。
enum CameraStateReducer {
  /// イベントを処理し、次の State と副作用を返します。
  ///
  /// - Returns: 更新後の State と実行すべき Effect のリスト
  static func reduce(
    state: CameraState,
    event: CameraEvent
  ) -> (state: CameraState, effects: [CameraEffect]) {
    var state = state
    var effects: [CameraEffect] = []

    switch event {
    // カメラ開始の要求: format の解決と native start を待つ。
    // active capturer は native start の成功時に設定する。
    // (開始要求の時点で設定すると、開始に失敗した camera が current として観測される)
    // 古い世代の要求は破棄する (隔離で世代が進んだ後に届いた要求で隔離を解除しない)。
    // production は owner の採番値 (等値) を渡すが、採番を経由せず新しい世代を直接
    // 渡す経路も受け付けるため `>=` で判定する。
    // 対象 ID は command が自分の入力として保持しており、この遷移では使わない。
    case .startRequested(_, let generation):
      guard generation >= state.operationGeneration else {
        break
      }
      state.phase = .starting
      state.operationGeneration = generation
      effects.append(.publishSnapshot)

    // format の解決完了: フレームレートを記録する。
    // 古い generation の解決結果は破棄する。
    case .formatResolved(let id, let frameRate, let generation):
      guard generation == state.operationGeneration else {
        break
      }
      state.frameRates[id] = frameRate
      effects.append(.publishSnapshot)

    // カメラ開始の完了: 成功なら動作中へ、失敗なら停止状態へ戻す。
    case .startCompleted(let id, let generation, let success):
      guard generation == state.operationGeneration else {
        break
      }
      if success {
        state.phase = .running
        state.activeCapturerID = id
        state.runningCapturers.insert(id)
      } else {
        // 開始に失敗した場合は動作中へ移さない。
        // active は開始成功時にしか設定しないため、ここでは解除しない。
        state.phase = .idle
        state.runningCapturers.remove(id)
      }
      effects.append(.publishSnapshot)

    // カメラ停止 / 再起動 / 設定変更の要求: native stop から始める。
    // restart と change は内部 stop → start の複合コマンドとして同じ遷移を使う。
    // active / running の解除は内部 stop の完了 (.stopCompleted) で行う。
    // 古い世代の要求は破棄する (隔離で世代が進んだ後に届いた要求で隔離を解除しない)。
    // 対象 ID は command が自分の入力として保持しており、この遷移では使わない。
    case .stopRequested(_, let generation),
      .restartRequested(_, let generation),
      .changeRequested(_, let generation):
      guard generation >= state.operationGeneration else {
        break
      }
      state.phase = .stopping
      state.operationGeneration = generation
      effects.append(.publishSnapshot)

    // カメラ停止の完了: 動作状態と active を解除する。
    //
    // 複合コマンド (restart / change / flip) の内部 stop もこのイベントを使います。
    // これにより、内部 stop が完了した時点で current / isRunning が解除され、
    // 単体の stop と同じ観測結果になります。
    case .stopCompleted(let id, let generation):
      guard generation == state.operationGeneration else {
        break
      }
      state.runningCapturers.remove(id)
      state.phase = .idle
      // 停止した capturer が active の場合だけ解除する
      // (複合コマンドの内部 stop も同じ ID のため、通常は一致する)
      if state.activeCapturerID == id {
        state.activeCapturerID = nil
      }
      effects.append(.publishSnapshot)

    // カメラ再起動 / 設定変更の完了: 成功なら動作中へ、失敗なら停止状態へ戻す。
    // (内部 stop 成功後に start が失敗した場合も、カメラ未稼働として idle に落とす)
    // 停止済みの状態からも実行されるため、成功時は active を設定する。
    case .restartCompleted(let id, let generation, let success),
      .changeCompleted(let id, let generation, let success):
      guard generation == state.operationGeneration else {
        break
      }
      if success {
        state.phase = .running
        state.activeCapturerID = id
        state.runningCapturers.insert(id)
      } else {
        state.phase = .idle
        state.runningCapturers.remove(id)
        state.activeCapturerID = nil
      }
      effects.append(.publishSnapshot)

    // カメラ切り替えの要求: 切り替え元の native stop を待つ。
    // 切り替え先は command が解決済みの ID を渡す。
    // 切り替え元の解除は内部 stop の完了 (.stopCompleted) で行う。
    // 古い世代の要求は破棄する。
    // 切り替え元 / 先の ID は command が自分の入力として保持しており、この遷移では使わない。
    case .flipRequested(_, _, let generation):
      guard generation >= state.operationGeneration else {
        break
      }
      state.phase = .flipping
      state.isFlipping = true
      state.operationGeneration = generation
      effects.append(.publishSnapshot)

    // カメラ切り替えの完了: 成功なら切り替え先を active へ移す。
    // 失敗時は切り替え元も切り替え先も停止した状態になる。
    case .flipCompleted(let sourceID, let targetID, let generation, let success):
      guard generation == state.operationGeneration else {
        break
      }
      state.isFlipping = false
      state.runningCapturers.remove(sourceID)
      if success {
        state.activeCapturerID = targetID
        state.runningCapturers.insert(targetID)
        state.phase = .running
      } else {
        state.runningCapturers.remove(targetID)
        state.activeCapturerID = nil
        state.phase = .idle
      }
      effects.append(.publishSnapshot)

    // 隔離: phase を quarantined へ移す。
    // 世代を進めることで、隔離後に到着した古い callback が隔離を解除しないようにする。
    // 実行中の flip は完了しても適用されないため、ここで re-entrance を解除する。
    case .quarantined:
      state.phase = .quarantined
      state.operationGeneration &+= 1
      state.isFlipping = false
      effects.append(.publishSnapshot)

    // 隔離の解除: 隔離中のときだけ idle へ戻す。
    // (未隔離の停止完了でも送られるため、進行中の phase を壊さない)
    case .quarantineCleared:
      if state.phase == .quarantined {
        state.phase = .idle
      }
      effects.append(.publishSnapshot)

    // capturer instance の解放: その ID に紐付く state を破棄する。
    // instance の deinit から通知される。active capturer と動作中の instance は
    // owner の強参照ストレージが保持するため通常は解放されず、active の解除は
    // 不変条件が崩れた場合の防御として行う。
    case .capturerReleased(let id):
      state.frameRates[id] = nil
      state.runningCapturers.remove(id)
      if state.activeCapturerID == id {
        state.activeCapturerID = nil
      }
      effects.append(.publishSnapshot)
    }

    return (state, effects)
  }
}
