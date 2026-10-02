import Foundation
import XCTest

@testable import Sora

// concurrency runtime stress test です。
//
// Thread Sanitizer (TSan) はデータ競合を確率的にしか検出しないため、対象の API を
// 同一 instance に対して複数スレッドから交差させ、その交差を反復します。
// モックやスタブは使用せず、実 `ConnectionStateOwner` / 実 `ConnectionTimer` / 実ハンドラクラス /
// 実 `MediaChannel` / 実 `MediaStream` だけを使います。
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
// ハンドラクラス (`MediaChannelHandlers` / `WebSocketChannelHandlers` /
// `CameraVideoCapturerHandlers` / `MediaStreamHandlers`) のイベントハンドラのプロパティの排他と、
// `MediaChannel.handlers` の参照の排他も本ファイルで交差させます
// (`testHandlerBagReadWriteRaceWithDelivery`)。

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

/// 実配送経路が closure を呼んだ回数を集約する accumulator です。
///
/// 並行区間の中から `XCTAssert*` を呼ばずに済むよう、結果は lock 付きでこの型へ集めます。
/// `ConcurrencyStressRecorder` とは数える対象が違う (あちらは timeout handler の呼び出し、
/// こちらはハンドラの配送) ため、recorder を分けています。
///
/// TSan を無効にした通常の実行でも、配送経路が実際に呼ばれたこと (交差が空振りしていないこと)
/// を検証するために使います。
private final class ConcurrencyStressHandlerBagRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var deliveryCount = 0

  /// 実配送経路から closure が呼ばれた回数を 1 増やします。
  func recordDelivery() {
    lock.lock()
    defer { lock.unlock() }
    deliveryCount += 1
  }

  /// 実配送経路から closure が呼ばれた回数。
  var deliveredCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return deliveryCount
  }
}

/// 交差させる実ハンドラクラスと、その配送経路を持つ実 object をまとめた、テストローカルの
/// 用途限定 box です。
///
/// `DispatchQueue.concurrentPerform` の closure は `@Sendable` のため、非 `Sendable` な
/// ハンドラクラスを直接 capture できません。`@unchecked Sendable` を認める根拠は、この型が
/// 可変状態を持たず、保持する参照がすべて `let` であることです。保持する object の可変状態
/// (ハンドラクラスのイベントハンドラのプロパティ、`MediaChannel.handlers` の参照、`MediaStream` の有効
/// フラグ) の排他は SDK 側の責務であり、この box は交差の入口を渡すだけで、排他を
/// 肩代わりしません。`MediaChannel` と `MediaStream` は接続を開始しないため、ここで交差する
/// のは handler の読み書きと `videoEnabled` の確定経路だけです。
private final class ConcurrencyStressHandlerBagBox: @unchecked Sendable {
  let mediaChannelHandlers: MediaChannelHandlers
  let webSocketChannelHandlers: WebSocketChannelHandlers
  let cameraHandlers: CameraVideoCapturerHandlers
  let mediaChannel: MediaChannel
  let stream: MediaStream

  init(
    mediaChannelHandlers: MediaChannelHandlers,
    webSocketChannelHandlers: WebSocketChannelHandlers,
    cameraHandlers: CameraVideoCapturerHandlers,
    mediaChannel: MediaChannel,
    stream: MediaStream
  ) {
    self.mediaChannelHandlers = mediaChannelHandlers
    self.webSocketChannelHandlers = webSocketChannelHandlers
    self.cameraHandlers = cameraHandlers
    self.mediaChannel = mediaChannel
    self.stream = stream
  }
}

/// 排他が必要な共有状態の API を複数スレッドから交差させる concurrency runtime stress test です。
///
/// `ConnectionStateOwner` / `ConnectionTimer` の接続ライフサイクルと、ハンドラクラスの closure
/// property および `MediaChannel.handlers` の参照を対象にします。
///
/// TSan を有効にした実行でのデータ競合の検出を主目的とし、通常の実行でも論理的な不変条件
/// (受理 / 棄却の排他、非同期処理数の 1 対 1 対応、最終状態の整合、handler の配送が実際に
/// 呼ばれること) を検証します。TSan を無効にしないと通らない test は追加しません。
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

  /// 4 つのハンドラクラスのイベントハンドラのプロパティ 16 個と `MediaChannel.handlers` の参照の get / set を
  /// 複数スレッドから交差させ、`MediaStreamHandlers.onSwitchVideo` は実配送経路の読み取りとも
  /// 同じ並行区間で交差させます。
  ///
  /// ハンドラクラスのイベントハンドラのプロパティは、利用者が任意の executor から設定し、SDK が配送 executor
  /// から読む。この test は 1 つの並行区間の中で設定と配送の読み取りを重ねられる状態を作り、
  /// その交差を 8 ラウンド反復して TSan の検出窓を広げます (`concurrentPerform` は全 iteration の
  /// 完了まで戻るため、区間の外の処理とは重なりません)。
  ///
  /// 実配送経路は `MediaStream.videoEnabled` の確定を使います。この setter は世代を採番して
  /// `commitVideoEnabled` を呼び、値が変化したときに `MediaStreamHandlers.onSwitchVideo` を読んで
  /// 呼ぶため、handler を配送側から読む経路です。実 Sora 接続を必要としないため、
  /// `SORA_SIGNALING_URL` が無い環境でも実行されます。`CameraVideoCapturerHandlers` の
  /// `onCapture` / `onStart` / `onStop` の配送は実カメラが必要で Simulator では駆動できないため、
  /// これらは get / set の交差だけを行います。
  ///
  /// 配送を駆動するのは 1 スレッドだけにします。`videoEnabled` の setter は native track の
  /// `isEnabled` も書くため、複数スレッドから駆動すると handler ではなく libwebrtc 側で競合し、
  /// handler の排他の検証にならないからです。
  ///
  /// 通常の実行では、round ごとに配送経路が実際に呼ばれたこと (交差が空振りしていないこと) を
  /// 検証します。
  func testHandlerBagReadWriteRaceWithDelivery() throws {
    let mediaChannel = try makeTestMediaChannel()
    let stream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let recorder = ConcurrencyStressHandlerBagRecorder()
    let box = ConcurrencyStressHandlerBagBox(
      mediaChannelHandlers: MediaChannelHandlers(),
      webSocketChannelHandlers: WebSocketChannelHandlers(),
      cameraHandlers: CameraVideoCapturerHandlers(),
      mediaChannel: mediaChannel,
      stream: stream)

    for round in 0..<rounds {
      let deliveriesBeforeRound = recorder.deliveredCount

      // 配送を駆動する並行区間の間、`onSwitchVideo` が non-nil であることを保証する。nil を読むと
      // 配送が起きず、「交差が空振りしていないこと」を配送の呼び出し回数から判定できなくなる。
      box.stream.handlers.onSwitchVideo = { _ in
        recorder.recordDelivery()
      }

      // 16 個のイベントハンドラのプロパティと `MediaChannel.handlers` の参照を 64 スレッドで交差させる。
      // `onSwitchVideo` はここで設定し、同じ区間で配送 (index 0 の `videoEnabled` の確定) が
      // 読むため、読み書きが交差する。
      DispatchQueue.concurrentPerform(iterations: iterationsPerRound) { index in
        switch index % 16 {
        case 0:
          box.mediaChannelHandlers.onConnect = { _ in }
          _ = box.mediaChannelHandlers.onConnect
        case 1:
          box.mediaChannelHandlers.onDisconnectLegacy = { _ in }
          _ = box.mediaChannelHandlers.onDisconnectLegacy
        case 2:
          box.mediaChannelHandlers.onDisconnect = { _ in }
          _ = box.mediaChannelHandlers.onDisconnect
        case 3:
          box.mediaChannelHandlers.onAddStream = { _ in }
          _ = box.mediaChannelHandlers.onAddStream
        case 4:
          box.mediaChannelHandlers.onRemoveStream = { _ in }
          _ = box.mediaChannelHandlers.onRemoveStream
        case 5:
          box.mediaChannelHandlers.onReceiveSignalingJSON = { _ in }
          _ = box.mediaChannelHandlers.onReceiveSignalingJSON
        case 6:
          box.mediaChannelHandlers.onReceiveSignaling = { _ in }
          _ = box.mediaChannelHandlers.onReceiveSignaling
        case 7:
          box.mediaChannelHandlers.onDataChannel = { _ in }
          _ = box.mediaChannelHandlers.onDataChannel
        case 8:
          box.mediaChannelHandlers.onDataChannelOpened = { _, _ in }
          _ = box.mediaChannelHandlers.onDataChannelOpened
        case 9:
          box.mediaChannelHandlers.onDataChannelMessage = { _, _, _ in }
          _ = box.mediaChannelHandlers.onDataChannelMessage
        case 10:
          box.webSocketChannelHandlers.onReceive = { _ in }
          _ = box.webSocketChannelHandlers.onReceive
        case 11:
          box.cameraHandlers.onCapture = { _, frame in frame }
          _ = box.cameraHandlers.onCapture
        case 12:
          box.cameraHandlers.onStart = { _ in }
          _ = box.cameraHandlers.onStart
        case 13:
          box.cameraHandlers.onStop = { _ in }
          _ = box.cameraHandlers.onStop
        case 14:
          // `MediaChannel.handlers` の参照の差し替えと読み取り
          box.mediaChannel.handlers = MediaChannelHandlers()
          _ = box.mediaChannel.handlers.onDisconnect
        default:
          // 配送経路が読む `onSwitchVideo` の設定と読み取り。同じ区間の index 0 が配送を駆動する。
          box.stream.handlers.onSwitchVideo = { _ in
            recorder.recordDelivery()
          }
          _ = box.stream.handlers.onSwitchVideo
          box.stream.handlers.onSwitchAudio = { _ in }
          _ = box.stream.handlers.onSwitchAudio
        }

        // index 0 のスレッドだけが実配送を駆動する。値を交互に進め、値が変化するたびに
        // `onSwitchVideo` の読み取りと配送が起きるようにする。
        if index == 0 {
          for valueIndex in 0..<8 {
            box.stream.videoEnabled = (round + valueIndex) % 2 == 0
          }
        }
      }

      // round の区切りで nil の代入も write-vs-write として交差させる。次の round の先頭で
      // non-nil に戻すため、配送の判定には影響しない。
      DispatchQueue.concurrentPerform(iterations: iterationsPerRound) { index in
        if index % 2 == 0 {
          box.stream.handlers.onSwitchVideo = nil
        } else {
          box.stream.handlers.onSwitchVideo = { _ in
            recorder.recordDelivery()
          }
        }
      }

      // 各 round で配送が起きたことを、round の前後差で確認する。累積回数と比べると、空振りした
      // round を後続 round の回数で埋め合わせてしまう。
      XCTAssertGreaterThan(
        recorder.deliveredCount, deliveriesBeforeRound,
        "round \(round) で実配送経路 (`videoEnabled` の確定) が `onSwitchVideo` を呼んでいること")
    }

    // getter が最後に設定した closure を返すこと (並行区間の外での確認)。
    box.stream.handlers.onSwitchVideo = nil
    XCTAssertNil(box.stream.handlers.onSwitchVideo, "最後に設定した nil が getter から読めること")

    // stream owner を無効化し、以降の frame 配送を止める。
    stream.terminate()
  }

  /// 配送された closure から同じ handler を設定し直しても deadlock しないことを確認します。
  ///
  /// ハンドラクラスの getter は lock を解放してから closure を返し、配送側は lock を保持せずに
  /// closure を呼びます。この契約が壊れて「lock を保持したまま closure を呼ぶ」実装になると、
  /// この test は失敗ではなく deadlock (CI のタイムアウト) になります。
  func testHandlerReentrancyDoesNotDeadlock() throws {
    let mediaChannel = try makeTestMediaChannel()
    let stream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let recorder = ConcurrencyStressHandlerBagRecorder()
    let replacementCallCount = ConcurrencyStressHandlerBagRecorder()

    // 配送された closure から、同じ property と別の property を設定し直す。差し替え後は別の
    // counter を増やし、差し替えが握り潰された場合 (旧 closure が呼ばれ続けた場合) を区別できる
    // ようにする。
    stream.handlers.onSwitchVideo = { _ in
      recorder.recordDelivery()
      stream.handlers.onSwitchVideo = { _ in
        replacementCallCount.recordDelivery()
      }
      stream.handlers.onSwitchAudio = { _ in }
    }

    // `videoEnabled` の確定経路で closure を配送する。video track を持つ stream の `videoEnabled`
    // は既定で true のため、現在値の反転で必ず値が変化するようにする。初回は設定した closure が
    // 呼ばれる。
    let initialVideoEnabled = stream.videoEnabled
    stream.videoEnabled = !initialVideoEnabled
    XCTAssertEqual(recorder.deliveredCount, 1, "配送された closure が呼ばれていること")
    XCTAssertEqual(replacementCallCount.deliveredCount, 0, "差し替え後の closure はまだ呼ばれないこと")

    // 2 回目は closure の中で差し替えた closure が呼ばれる。deadlock する実装ではここに到達しない。
    stream.videoEnabled = initialVideoEnabled
    XCTAssertEqual(replacementCallCount.deliveredCount, 1, "差し替え後の closure が配送されること")
    XCTAssertEqual(recorder.deliveredCount, 1, "差し替え後の配送で旧 closure は呼ばれないこと")

    stream.terminate()
  }
}
