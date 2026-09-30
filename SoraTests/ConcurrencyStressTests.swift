import Foundation
import XCTest

@testable import Sora

// concurrency runtime stress test です。
//
// Thread Sanitizer (TSan) はデータ競合を確率的にしか検出しないため、対象の API を
// 同一 instance に対して複数スレッドから交差させ、その交差を反復します。
// モックやスタブは使用せず、実 `ConnectionStateOwner` と実 `ConnectionTimer` だけを使います。
//
// 反復回数と並行度の選定理由:
// - 並行度 64 は `PeerChannelConnectCompletionTests` / `StreamFrameOwnerTests` / `LoggerTests` と
//   同じ値です。これまで TSan で race を検出できた実績のある並行度に揃えます。
// - 反復回数 8 は 1 回の実行で全スレッドが同じ順序で進む確率を下げるための値です。
//   1 回の交差では race の窓に入らない実行順序でも、8 回反復すると窓に入る順序が現れます。
// - 判定は並行区間の外で行います。並行区間の中から `XCTAssert*` を呼ぶと、失敗の帰属が
//   実行順序に依存し、また XCTest の内部状態を別スレッドから触ることになるためです
//   (`PeerChannelConnectCompletionTests` / `LoggerTests` / `StreamFrameOwnerTests` と同じ方針)。
//
// 0154 が扱う handler bag (`MediaChannelHandlers` / `WebSocketChannelHandlers` /
// `CameraVideoCapturerHandlers` / `MediaStreamHandlers`) の読み書きを並行させる stress は、
// 本ファイルの対象に含めません (issue 0119 のスコープ外)。

/// 並行実行した受理 / 棄却と、スレッドをまたいで数える残高を集約する accumulator です。
///
/// 並行区間の中から `XCTAssert*` を呼ばずに済むよう、結果は lock 付きでこの型へ集めます
/// (`StringCollector` / `ConnectTerminationAccumulator` と同じ方針)。
/// timeout handler は呼び出し回数と「1 回以上呼ばれたか」を数えます (回数の上限は
/// test 側がラウンド番号と比較して判定します)。
private final class ConcurrencyStressRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var acceptedBegins = 0
  private var immediateDisconnects = 0
  private var balance = 0
  private var handlerCallCount = 0
  private var handlerDelivered = false

  /// 接続開始の初期ロックの取得に成功した回数を 1 増やします。
  func recordAcceptedBegin() {
    lock.lock()
    defer { lock.unlock() }
    acceptedBegins += 1
  }

  /// 非同期処理数を 1 増やします。
  func increaseBalance() {
    lock.lock()
    defer { lock.unlock() }
    balance += 1
  }

  /// 非同期処理数を 1 減らします。
  func decreaseBalance() {
    lock.lock()
    defer { lock.unlock() }
    balance -= 1
  }

  /// 切断要求を即時に受理した回数を 1 増やします。
  func recordImmediateDisconnect() {
    lock.lock()
    defer { lock.unlock() }
    immediateDisconnects += 1
  }

  /// timeout handler が呼ばれた回数を 1 増やし、1 回以上呼ばれたことを記録します。
  func recordHandlerCall() {
    lock.lock()
    defer { lock.unlock() }
    handlerCallCount += 1
    handlerDelivered = true
  }

  /// 接続開始の初期ロックの取得に成功した回数を返します。
  var acceptedBeginCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return acceptedBegins
  }

  /// 切断要求を即時に受理した回数を返します。
  var immediateDisconnectCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return immediateDisconnects
  }

  /// 現在の非同期処理数の残高を返します。
  var currentBalance: Int {
    lock.lock()
    defer { lock.unlock() }
    return balance
  }

  /// timeout handler が呼ばれた回数を返します。
  var handlerCalls: Int {
    lock.lock()
    defer { lock.unlock() }
    return handlerCallCount
  }

  /// timeout handler が 1 回以上呼ばれたかを返します。
  var wasHandlerDelivered: Bool {
    lock.lock()
    defer { lock.unlock() }
    return handlerDelivered
  }
}

/// `@Sendable` ではない handler を `DispatchQueue.concurrentPerform` の `@Sendable` closure へ
/// 渡すための、テストローカルの用途限定 box です。
///
/// `ConnectionTimer.run` の handler は `Sendable` な closure へ直接 capture できないため、
/// 不変の handler を `let` で保持するこの型へ包みます。`@unchecked Sendable` を認める根拠は、
/// この型が可変状態を持たず、保持する handler が `init` で確定した `let` であり、この test の
/// 中で 1 つの handler を複数スレッドから呼ぶだけで、handler 自身が `Sendable` な recorder しか
/// 捕捉しないことです (同じ数の引数と戻り値で、別系統の境界へ新たに渡すことはない)。
private final class ConcurrencyStressHandlerBox: @unchecked Sendable {
  private let handler: () -> Void

  init(_ handler: @escaping () -> Void) {
    self.handler = handler
  }

  func callAsFunction() {
    handler()
  }
}

/// `ConnectionStateOwner` の接続ライフサイクルの排他 API を複数スレッドから交差させる
/// concurrency runtime stress test です。
///
/// TSan を有効にした実行でのデータ競合の検出を主目的とし、通常の実行でも論理的な
/// 不変条件 (受理 / 棄却の排他、非同期処理数の 1 対 1 対応、最終状態の整合) を検証します。
/// TSan を無効にしないと通らない test は追加しません。
final class ConcurrencyStressTests: XCTestCase {
  /// 1 ラウンドあたりの交差の数 (既存 test と同じ並行度)
  private let iterationsPerRound = 64

  /// 1 つの test で反復するラウンド数
  private let rounds = 8

  // テストで共通利用するシグナリング URL を返します。
  private func makeTestURL() -> URL {
    guard let url = URL(string: "wss://example.com") else {
      fatalError("テスト URL の生成に失敗しました")
    }
    return url
  }

  // 接続試行中の `PeerChannel` を構築します。
  //
  // `onConnect` を設定した状態で `state` を読むと `.connecting` になります。
  // `ConnectionTimer` の timeout 経路は monitor の state が `.connecting` のときにだけ
  // handler を呼ぶため、timeout 配送を検証する test ではこの状態が必要です。
  // 切断経路でカメラ停止などの非同期 cleanup を起こさないよう recvonly で構築します。
  private func makePeerChannel() throws -> PeerChannel {
    let configuration = Configuration(
      urlCandidates: [makeTestURL()],
      channelId: "test",
      role: .recvonly)
    let snapshot = try ConnectionConfigurationSnapshot(configuration: configuration)
    let signalingChannel = SignalingChannel(
      snapshot: snapshot,
      webSocketChannelHandlers: configuration.webSocketChannelHandlers)
    let nativePeerChannelFactory = try NativePeerChannelFactory(bypassVoiceProcessing: false)
    return PeerChannel(
      snapshot: snapshot,
      signalingChannel: signalingChannel,
      nativePeerChannelFactory: nativePeerChannelFactory,
      mediaChannel: nil)
  }

  /// `beginConnectionStart` を 64 スレッドから交差させ、初期ロックの受理が 1 回だけであることを確認します。
  ///
  /// 初期ロックの取得可否は `ConnectionStateOwner` の直列 queue 上の排他区間で判定されるため、
  /// 1 ラウンドで受理される呼び出しは高々 1 回です。受理した 1 スレッドだけが初期ロックを解放し、
  /// ラウンド終了時の状態は初期状態へ戻ります (受理と棄却の排他、最終状態の整合)。
  /// この交差を 8 ラウンド反復し、検出窓を広げます。
  func testConnectionStartRaceAcceptsAtMostOncePerRound() {
    var acceptedTotal = 0

    for round in 0..<rounds {
      let owner = ConnectionStateOwner(snapshotStorage: ConnectionSnapshotStorage())
      let recorder = ConcurrencyStressRecorder()

      DispatchQueue.concurrentPerform(iterations: iterationsPerRound) { _ in
        if owner.beginConnectionStart() {
          recorder.recordAcceptedBegin()
        }
      }

      // 受理した 1 スレッドだけが初期ロックを解放する。
      if recorder.acceptedBeginCount == 1 {
        let pending = owner.finishSignalingStart { _ in false }
        XCTAssertNil(pending, "保存された切断要求が無い場合は何も返さないこと")
        XCTAssertNil(
          owner.endAsyncOperation { _ in false },
          "保存された切断要求が無い場合は何も返さないこと")
      }

      XCTAssertEqual(
        recorder.acceptedBeginCount, 1,
        "初期ロックを受理した呼び出しが 1 回であること (round: \(round))")
      let state = owner.stateForTesting()
      XCTAssertEqual(
        state.asyncOperationCount, 0,
        "ラウンド終了時に非同期処理数が 0 であること (round: \(round))")
      XCTAssertFalse(
        state.isStartingConnection,
        "ラウンド終了時に開始区間が閉じていること (round: \(round))")
      XCTAssertFalse(
        state.isDisconnecting,
        "切断要求を出していないラウンドでは切断処理が開始されないこと (round: \(round))")
      acceptedTotal += recorder.acceptedBeginCount
    }

    XCTAssertEqual(acceptedTotal, rounds, "各ラウンドで 1 回だけ受理されること")
  }

  /// `beginAsyncOperation` / `endAsyncOperation` / `requestDisconnect` を交差させ、
  /// 非同期処理数の残高が 0 に戻ることを確認します。
  ///
  /// 偶数 index は非同期処理の開始と終了の対 (開始に成功したら必ず 1 回終了する) を、
  /// 奇数 index は切断要求を実行します。切断要求を即時に受理する呼び出しは高々 1 回で、
  /// それ以外の呼び出しは棄却されるか遅延保存されます。開始に成功した呼び出しは必ず
  /// 1 回だけ終了を登録するため、ラウンド終了時の残高は 0 に戻ります。
  func testAsyncOperationRaceBalancesCountToZero() {
    for round in 0..<rounds {
      let owner = ConnectionStateOwner(snapshotStorage: ConnectionSnapshotStorage())
      let recorder = ConcurrencyStressRecorder()

      DispatchQueue.concurrentPerform(iterations: iterationsPerRound) { index in
        if index.isMultiple(of: 2) {
          // 開始に成功したら必ず 1 回終了する。終了は切断要求の有無にかかわらず呼ぶ。
          if owner.beginAsyncOperation() {
            recorder.increaseBalance()
            _ = owner.endAsyncOperation { _ in false }
            recorder.decreaseBalance()
          }
        } else {
          let immediate = owner.requestDisconnect(
            error: nil,
            reason: .user,
            shouldCancelDisconnectTimerBasedDisconnect: { _ in false },
            isConnectHandlerHeld: { false })
          if immediate != nil {
            recorder.recordImmediateDisconnect()
          }
        }
      }

      XCTAssertLessThanOrEqual(
        recorder.immediateDisconnectCount, 1,
        "即時に受理する切断要求は高々 1 回であること (round: \(round))")
      XCTAssertEqual(
        recorder.currentBalance, 0,
        "ラウンド終了時に非同期処理数の残高が 0 であること (round: \(round))")
      let state = owner.stateForTesting()
      XCTAssertEqual(
        state.asyncOperationCount, 0,
        "ラウンド終了時に owner の非同期処理数が 0 であること (round: \(round))")
      XCTAssertTrue(
        state.isDisconnecting,
        "切断要求が出ているラウンドでは切断処理が開始されていること (round: \(round))")
    }
  }

  /// `ConnectionTimer` の `run()` と `stop()` を複数スレッドから交差させ、
  /// timeout handler が 1 世代につき高々 1 回だけ呼ばれることを確認します。
  ///
  /// `run()` は呼ばれるたびに旧 Timer を invalidate して世代を進めるため、複数の `run()` が
  /// 交差しても handler を呼べるのは最後に確定した世代だけです。`stop()` は稼働中の Timer の
  /// 世代を進めるため、停止後の世代の callback は世代照合で棄却されます。
  /// ラウンドごとに「handler が呼ばれた回数 ≤ ラウンド数」を確認し、最後に 1 回だけ `run()` して
  /// 配送そのものを確認します (交差だけでは handler が一度も呼ばれず、判定が空振りになるため)。
  func testConnectionTimerRunStopRaceDeliversHandlerAtMostOncePerGeneration() throws {
    let peerChannel = try makePeerChannel()
    // connect() を経由せず onConnect を設定すると state は .connecting になる。
    // ConnectionTimer の timeout 経路はこの状態でだけ handler を呼ぶ。
    peerChannel.onConnect = { _ in }

    let recorder = ConcurrencyStressRecorder()
    // 交差させた run() の世代とは独立に、配送確認用の run() が使う handler。
    // 呼ばれた回数は recorder で数える (別スレッドからも呼ばれ得るため)。
    let handler: () -> Void = { recorder.recordHandlerCall() }
    let connectionTimer = ConnectionTimer(
      monitors: [.peerChannel(peerChannel)],
      timeout: 1)

    for round in 0..<rounds {
      // `concurrentPerform` の closure は `@Sendable` のため、`@Sendable` ではない
      // `ConnectionTimer.run` の handler は box へ包んでから capture する。
      let handlerBox = ConcurrencyStressHandlerBox(handler)
      DispatchQueue.concurrentPerform(iterations: iterationsPerRound) { index in
        if index.isMultiple(of: 2) {
          connectionTimer.run(timeout: 1, handler: handlerBox.callAsFunction)
        } else {
          connectionTimer.stop()
        }
      }

      XCTAssertLessThanOrEqual(
        recorder.handlerCalls, round + 1,
        "交差した run() の世代で handler が呼ばれるのは高々 1 世代であること (round: \(round))")
    }

    // 配送確認: 交差の後に 1 回だけ run() し、timeout で handler が呼ばれることを待つ。
    // `wait(for:timeout:)` は待機中も main RunLoop を回すため、main RunLoop に登録した Timer の
    // 満了と handler の呼び出しはこの待機の中で処理される。待ち時間は Timer の満了 (1 秒) に
    // 対して十分な 3 秒とし、満了前に判定して空振りにならないようにする。
    connectionTimer.run(timeout: 1, handler: handler)
    let delivered = self.expectation(description: "ConnectionTimer の timeout が配送されること")
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
      delivered.fulfill()
    }
    wait(for: [delivered], timeout: 5)

    XCTAssertTrue(
      recorder.wasHandlerDelivered,
      "timeout handler が 1 回以上呼ばれること (interceptor と世代照合の確認)")
    XCTAssertLessThanOrEqual(
      recorder.handlerCalls, rounds + 1,
      "handler が呼ばれるのは高々 1 世代につき 1 回であること")
    // 配送後は世代照合を通った経路が stop() を呼ぶため、Timer は停止している。
    XCTAssertFalse(
      connectionTimer.isRunning,
      "timeout の配送後は Timer が停止していること")
  }
}
