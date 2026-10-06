import Foundation
import WebRTC
import XCTest

@testable import Sora

// 送信経路 (`MediaChannel.sendMessage`) と RPC 経路 (`MediaChannel.performRPC`) が参照する
// `PeerChannel` の状態 (登録済みの `DataChannel` の辞書 / `switchedToDataChannel` /
// `rpcChannel`) と、
// redirect による無効化を複数スレッドから交差させる concurrency runtime stress test です。
//
// Thread Sanitizer (TSan) はデータ競合を確率的にしか検出しないため、対象の API を
// 同一 instance に対して複数スレッドから交差させ、その交差を反復します。
// モックやスタブは使用せず、実 `MediaChannel` / 実 `PeerChannel` / 実 `RTCPeerConnection` /
// 実 `RTCDataChannel` / 実 `DataChannel` / 実 `RPCChannel` だけを使います。
//
// redirect の無効化は `PeerChannel.invalidateMessagingAfterRedirect()` を直接呼びます。これは
// `handleSignalingOverWebSocket` の `.redirect` ケースが呼ぶ実経路です。redirect シグナリングを
// 受信する逐次経路は `PeerChannelRedirectInvalidationTests` が検証し、本ファイルは同じ排他区間へ
// 複数スレッドから入る交差だけを検証します。
//
// `Logger.shared` はプロセス全体の共有状態のため、このクラスのテストは直列実行を前提とします
// (`LoggerCallUnderLockTests` と同じ前提)。
//
// 反復回数と並行度の選定理由:
// - 反復回数 8 は `ConcurrencyStressTests` と同じ値です。1 回の交差では競合の窓に入らない
//   実行順序でも、8 回反復すると窓に入る順序が現れます。
// - 並行度 4 と 1 スレッドあたり 200 回の操作で、1 ラウンドあたり送信側と無効化側が
//   それぞれ 400 回ずつ排他区間へ入ります。この構成で対象の storage へ無同期にアクセスする
//   一時テストを TSan で実行すると report が 1 件以上出ることを確認しています。
// - 判定は並行区間の外で行います (`ConcurrencyStressTests` と同じ方針)。

/// DataChannel で受信したメッセージを観測する実 `RTCDataChannelDelegate` です。
///
/// モックではなく実プロトコルの実装であり、送信が実際に DataChannel を通ったことだけを
/// 記録します。`@unchecked Sendable` を認める根拠は、可変状態 (`receivedCount` / `expectation`) の
/// 読み書きをすべて `lock` で排他していることです (WebRTC の callback は別スレッドから届きます)。
private final class MessagingRaceMessageRecorder: NSObject, RTCDataChannelDelegate,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var receivedCount = 0
  private var expectation: XCTestExpectation?

  /// 待ち合わせを開始します。以降にメッセージを受信するたびに `expectation` を fulfill します。
  func arm(_ expectation: XCTestExpectation) {
    lock.lock()
    self.expectation = expectation
    lock.unlock()
  }

  func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
    // 状態遷移は観測しない
  }

  func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
    lock.lock()
    receivedCount += 1
    let expectation = self.expectation
    lock.unlock()
    expectation?.fulfill()
  }

  /// 受信したメッセージの件数を返します。
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return receivedCount
  }
}

/// 並行区間で観測した件数を `lock` で集約する accumulator です。
///
/// 並行区間の中から `XCTAssert*` を呼ばずに済むよう、件数はこの型へ集めます
/// (`ConcurrencyStressTests` の recorder と同じ方針)。`@unchecked Sendable` を認める根拠は、
/// 可変状態 (`count`) の読み書きを `lock` で排他していることです。
private final class MessagingRaceCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}

/// `didOpen` の実経路を専用 queue から呼ぶための、テストローカルの用途限定 box です。
///
/// `@unchecked Sendable` を認める根拠は、保持する参照が `init` で確定した `let` であり、
/// box 自身が可変状態を持たないことです。呼び出しは `PeerChannel.peerConnection(_:didOpen:)` の
/// 1 回だけで、状態アクセスは `PeerChannel` の内部同期に依存します (`MessagingRaceBox` と同じ方針)。
private final class MessagingRaceDidOpenBox: @unchecked Sendable {
  private let peerChannel: PeerChannel
  private let peerConnection: RTCPeerConnection
  private let dataChannel: RTCDataChannel

  init(peerChannel: PeerChannel, peerConnection: RTCPeerConnection, dataChannel: RTCDataChannel) {
    self.peerChannel = peerChannel
    self.peerConnection = peerConnection
    self.dataChannel = dataChannel
  }

  /// `RTCPeerConnectionDelegate` の `didOpen` 通知を呼びます。
  func callAsFunction() {
    peerChannel.peerConnection(peerConnection, didOpen: dataChannel)
  }
}

/// 非 Sendable な `MediaChannel` / `PeerChannel` / `DataChannel` を `@Sendable` な closure と
/// `Task` へ渡すための、テストローカルの用途限定 box です。
///
/// `@unchecked Sendable` を認める根拠は、保持する参照が `init` で確定した `let` であり、
/// box 自身が可変状態を持たないことです。box のメソッドが呼ぶ状態アクセスは、`MediaChannel` /
/// `PeerChannel` の内部同期 (`ConnectionStateOwner` の直列 queue、各 storage の NSLock、
/// `RPCChannel` の barrier) に依存します (`ConcurrencyStressE2ETests` の
/// `StressRPCChannelBox` と同じ方針)。この `@unchecked Sendable` は `MediaChannel` /
/// `PeerChannel` / `DataChannel` 全体が thread-safe であることを主張しません。
private final class MessagingRaceBox: @unchecked Sendable {
  private let mediaChannel: MediaChannel
  private let peerChannel: PeerChannel
  private let dataChannel: DataChannel

  init(mediaChannel: MediaChannel, dataChannel: DataChannel) {
    self.mediaChannel = mediaChannel
    self.peerChannel = mediaChannel.peerChannel
    self.dataChannel = dataChannel
  }

  /// `MediaChannel.sendMessage` を呼びます。
  func sendMessage(_ data: Data) -> Error? {
    mediaChannel.sendMessage(label: dataChannel.label, data: data)
  }

  /// `didOpen` と同じ登録経路で DataChannel を登録します。
  ///
  /// `withRPCChannel` が true の場合は新しい `RPCChannel` を同じ排他区間で設定します。本番の
  /// `didOpen` は登録のたびに新しい `RPCChannel` を生成するため、テストも同じ形にします。
  func register(withRPCChannel: Bool = false) {
    peerChannel.register(
      dataChannel: dataChannel,
      rpcChannel: withRPCChannel ? RPCChannel(dataChannel: dataChannel) : nil)
  }

  /// `type: switched` 受信時の状態更新を模します。
  func markSwitchedToDataChannel() {
    peerChannel.switchedToDataChannel = true
  }

  /// redirect 受理時の無効化 (`handleSignalingOverWebSocket` の `.redirect` ケースが呼ぶ実経路) を
  /// 呼びます。取り出した `RPCChannel` の `invalidate(reason:)` も本番と同じく排他区間の外で
  /// 呼びます (pending の completion を同期的に呼ぶため)。
  func invalidateMessagingAfterRedirect() {
    if let invalidatedRPCChannel = peerChannel.invalidateMessagingAfterRedirect() {
      invalidatedRPCChannel.invalidate(
        reason: SoraError.rpcDataChannelClosed(reason: "redirect"))
    }
  }

  /// 切断の実経路 (`basicDisconnect` が `takeRPCChannel()` で `rpcChannel` を nil にする経路) を
  /// 呼びます。
  func disconnect() {
    peerChannel.disconnect(error: nil, reason: .user)
  }

  /// DataChannel の delegate スレッドからの RPC メッセージ処理を呼びます。
  func handleRPCMessage(_ data: Data) {
    peerChannel.handleRPCMessage(data)
  }

  /// `MediaChannel.performRPC` と同じ読み取り経路で `RPCChannel` の参照を読みます。
  var currentRPCChannel: RPCChannel? {
    peerChannel.rpcChannel
  }

  /// `MediaChannel.rpc` (`performRPC` の共通経路) を notification として呼びます。
  func callRPCAsNotification() async throws {
    _ = try await mediaChannel.rpc(
      method: RequestSimulcastRid.self,
      params: RequestSimulcastRidParams(rid: .r0),
      isNotificationRequest: true,
      timeout: 0.01)
  }
}

/// WebRTC の callback とテストスレッド間の値を `lock` で受け渡す箱です。
///
/// `@unchecked Sendable` としているのは、可変状態が `value` だけで、その読み書きを
/// すべて `lock` で排他しているためです (WebRTC の callback は別スレッドから届きます)。
private final class MessagingRaceLockedValue<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value?

  func set(_ value: Value) {
    lock.lock()
    self.value = value
    lock.unlock()
  }

  func get() -> Value? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

/// `MediaChannel.sendMessage` と redirect の無効化、および RPC 経路の参照取得を
/// 複数スレッドから交差させる concurrency runtime stress test です。
///
/// TSan を有効にした実行でのデータ競合の検出を主目的とし、通常の実行でも論理的な不変条件
/// (無効化の完了後に開始した送信が旧 DataChannel へ届かないこと、無効化後の RPC が失敗すること)
/// を検証します。TSan を無効にしないと通らない test は追加しません。
final class PeerChannelMessagingRaceTests: XCTestCase {
  /// 1 ラウンドあたりの並行度
  private let concurrentWorkers = 4

  /// 1 スレッドあたりの操作回数
  private let operationsPerWorker = 200

  /// 1 つの test で反復するラウンド数
  private let rounds = 8

  /// テストの間、実 `MediaChannel` を保持します。
  ///
  /// `RTCPeerConnectionFactory` は PeerConnection より長生きさせる必要があります
  /// (先に解放すると、transceiver の破棄が破棄済みの task queue を参照してクラッシュします)。
  /// `MediaChannel` は自身の `PeerChannel` 経由で factory を保持するため、instance で保持して
  /// テストメソッドのローカル変数より後に解放されるようにします。
  private var mediaChannel: MediaChannel?

  /// テストの間、ローカル接続に使う実 `RTCPeerConnection` を保持します。
  private var peerConnections: [RTCPeerConnection] = []

  /// テストの間、delegate を外す対象の実 `RTCDataChannel` を保持します。
  private var nativeDataChannels: [RTCDataChannel] = []

  /// deadlock で停止した経路がある場合は true になり、後始末で SDK の状態を触りません
  /// (停止した排他単位を待たないため。`LoggerCallUnderLockTests` と同じ方針)。
  private var hasStuckPath = false

  override func tearDown() {
    if !hasStuckPath {
      // PeerConnection を閉じる前に delegate を外し、テスト終了後に SDK の切断経路が
      // 走らないようにする。その後に PeerConnection、最後に factory を保持する
      // MediaChannel の参照を落とす。
      for dataChannel in nativeDataChannels {
        dataChannel.delegate = nil
      }
      nativeDataChannels = []
      peerConnections = []
      mediaChannel = nil
    }
    hasStuckPath = false
    super.tearDown()
  }

  // MARK: - sendMessage と redirect の無効化

  /// `sendMessage` と redirect の無効化を複数スレッドから交差させます。
  ///
  /// 送信側は実際に OPEN な DataChannel へ送信し、無効化側は新しい接続の DataChannel 登録
  /// (`didOpen` と同じ経路)・`switchedToDataChannel` の更新・redirect の無効化を繰り返します。
  /// 交差の後、無効化が完了してから開始した `sendMessage` が旧 DataChannel へ送信せず
  /// `SoraError.messagingError` を返すことを固定します。
  func testSendMessageAndRedirectInvalidationRace() throws {
    let mediaChannel = try makeTestMediaChannel()
    self.mediaChannel = mediaChannel
    let pair = try makeOpenDataChannelPair(mediaChannel: mediaChannel, label: "#spam")
    let box = MessagingRaceBox(mediaChannel: mediaChannel, dataChannel: pair.sendSide)
    box.register()
    box.markSwitchedToDataChannel()

    let payload = Data([0x01])
    let workers = concurrentWorkers
    let operations = operationsPerWorker
    let sentCount = MessagingRaceCounter()
    for round in 0..<rounds {
      // ラウンドの先頭で送信可能な状態に戻し、交差が空振りしていないことを確認できるようにする
      box.register()
      box.markSwitchedToDataChannel()
      let sentBeforeRound = sentCount.value
      DispatchQueue.concurrentPerform(iterations: workers) { index in
        if index.isMultiple(of: 2) {
          // 利用者のスレッドからの送信を模す
          for _ in 0..<operations {
            if box.sendMessage(payload) == nil {
              sentCount.increment()
            }
          }
        } else {
          // 新しい接続の DataChannel 登録と redirect の無効化を模す
          for _ in 0..<operations {
            box.register()
            box.markSwitchedToDataChannel()
            box.invalidateMessagingAfterRedirect()
          }
        }
      }
      // 送信経路が実際に使われたこと (交差が空振りしていないこと) をラウンドごとに確認する
      XCTAssertGreaterThan(
        sentCount.value, sentBeforeRound,
        "ラウンド \(round) で登録済みの DataChannel への送信が成功していること")
    }

    // 無効化が完了した後に開始した送信は、旧 DataChannel へ送信せずエラーを返す
    box.register()
    box.markSwitchedToDataChannel()
    box.invalidateMessagingAfterRedirect()
    XCTAssertEqual(
      try messagingErrorReason(box.sendMessage(payload)),
      "DataChannel is not open yet",
      "無効化の完了後に開始した sendMessage が旧 DataChannel への送信を拒否すること")
  }

  /// redirect の無効化が完了した後に開始した `sendMessage` が、実際に旧 DataChannel へ
  /// 届かないことをローカル接続した実 DataChannel で確認します。
  ///
  /// 無効化の前は同じ経路の送信が対向の DataChannel に届くことも合わせて固定します
  /// (送信経路が生きている状態で、無効化だけが送信を止めたことを区別するため)。
  func testSendMessageAfterRedirectInvalidationDoesNotReachOldDataChannel() throws {
    let mediaChannel = try makeTestMediaChannel()
    self.mediaChannel = mediaChannel
    let peerChannel = mediaChannel.peerChannel
    let pair = try makeOpenDataChannelPair(mediaChannel: mediaChannel, label: "#spam")
    let recorder = MessagingRaceMessageRecorder()
    pair.incoming.delegate = recorder

    let box = MessagingRaceBox(mediaChannel: mediaChannel, dataChannel: pair.sendSide)
    box.register()
    box.markSwitchedToDataChannel()

    // 無効化の前は送信が対向の DataChannel に届くことを固定する
    XCTAssertNil(
      box.sendMessage(Data([0x01])), "OPEN な DataChannel への送信が成功すること")
    let delivered = expectation(
      for: NSPredicate { _, _ in recorder.count == 1 }, evaluatedWith: nil)
    wait(for: [delivered], timeout: 10)
    XCTAssertEqual(recorder.count, 1, "無効化の前の送信が対向の DataChannel に 1 件届くこと")

    // redirect の無効化 (switchedToDataChannel / 登録済みの DataChannel / rpcChannel の無効化)
    box.invalidateMessagingAfterRedirect()
    XCTAssertNil(
      peerChannel.dataChannel(label: "#spam"),
      "無効化の完了後に旧 DataChannel の参照が解放されていること")

    // 無効化の完了後に開始した送信は旧 DataChannel へ届かない
    let noDelivery = expectation(description: "無効化後の送信が旧 DataChannel へ届かないこと")
    noDelivery.isInverted = true
    recorder.arm(noDelivery)
    XCTAssertEqual(
      try messagingErrorReason(box.sendMessage(Data([0x02]))),
      "DataChannel is not open yet",
      "無効化の完了後に開始した sendMessage が旧 DataChannel への送信を拒否すること")
    wait(for: [noDelivery], timeout: 1)
    XCTAssertEqual(
      recorder.count, 1,
      "無効化の完了後に開始した送信が旧 DataChannel へ届かないこと (受信件数が増えないこと)")
  }

  /// 圧縮に失敗した送信が `SoraError.messagingError` を返し、対向の DataChannel へ届かないことを
  /// 確認します。
  ///
  /// `ZLibUtil.zip` は空の `Data` で nil を返すため、`compress: true` の DataChannel へ空の
  /// `Data` を送ると `DataChannel.sendWithoutLogging(_:)` の `.compressionFailed` を決定的に
  /// 通ります。`MediaChannel.sendMessage` は失敗を一律の reason で返すため、原因が error
  /// ログに残ることも合わせて固定します。
  func testSendMessageCompressionFailureReturnsError() throws {
    let mediaChannel = try makeTestMediaChannel()
    self.mediaChannel = mediaChannel
    let pair = try makeOpenDataChannelPair(
      mediaChannel: mediaChannel, label: "#spam", compress: true)
    let recorder = MessagingRaceMessageRecorder()
    pair.incoming.delegate = recorder

    let box = MessagingRaceBox(mediaChannel: mediaChannel, dataChannel: pair.sendSide)
    box.register()
    box.markSwitchedToDataChannel()

    // 圧縮失敗の原因が error ログに残ることを観測する (Logger は送信スレッドで handler を
    // 同期呼び出しするため、送信の直後に確認できる)
    let originalLevel = Logger.shared.level
    let originalGroups = Logger.shared.groups
    let originalHandler = Logger.shared.onOutputHandler
    defer {
      Logger.shared.onOutputHandler = originalHandler
      Logger.shared.level = originalLevel
      Logger.shared.groups = originalGroups
    }
    Logger.shared.level = .debug
    Logger.shared.groups = [.channels]
    let compressionFailureLogged = MessagingRaceLockedValue<Bool>()
    Logger.shared.onOutputHandler = { log in
      if log.message == "failed to compress message" {
        compressionFailureLogged.set(true)
      }
    }

    // 圧縮に失敗した送信は対向の DataChannel へ届かない
    let noDelivery = expectation(description: "圧縮に失敗した送信が旧 DataChannel へ届かないこと")
    noDelivery.isInverted = true
    recorder.arm(noDelivery)

    XCTAssertEqual(
      try messagingErrorReason(box.sendMessage(Data())),
      "failed to send message: label => #spam",
      "圧縮に失敗した送信が messagingError を返すこと")
    XCTAssertEqual(
      compressionFailureLogged.get(), true, "圧縮に失敗した原因が error ログに出ること")
    wait(for: [noDelivery], timeout: 1)
    XCTAssertEqual(
      recorder.count, 0, "圧縮に失敗した送信が対向の DataChannel へ届かないこと")
  }

  /// `didOpen` が `onOpenDataChannel` を通知する前に DataChannel の登録と `rpcChannel` の
  /// 設定を終えていることを確認します。
  ///
  /// 「登録済みだが RPC が未設定」の窓が無いこと自体は、登録と設定を同じ排他区間で行う実装が
  /// 担保します。ここでは通知時点で両方が参照できることを固定します。通知は排他区間の外で
  /// 呼ばれる契約であり、区間の中で呼ぶ退行では通知先の参照読みが非再帰ロックで停止するため、
  /// 通知元は専用 queue から実行し、テストスレッドは expectation を待つだけにします。
  func testDidOpenRegistersRPCChannelBeforeOpenNotification() throws {
    let mediaChannel = try makeTestMediaChannel()
    self.mediaChannel = mediaChannel
    let peerChannel = mediaChannel.peerChannel
    let pair = try makeOpenDataChannelPair(mediaChannel: mediaChannel, label: "rpc")
    // didOpen は現在の RTCPeerConnection からの通知だけを受け付ける
    peerChannel.nativeChannel = pair.outgoingPeerConnection
    defer {
      // handler が peerChannel を捕捉する循環参照を切る
      peerChannel.internalHandlers.onOpenDataChannel = nil
      peerChannel.nativeChannel = nil
    }

    let observed = MessagingRaceLockedValue<
      (label: String, isRegistered: Bool, hasRPCChannel: Bool)
    >()
    let notified = expectation(description: "onOpenDataChannel が rpc ラベルで呼ばれること")
    peerChannel.internalHandlers.onOpenDataChannel = { label in
      observed.set(
        (
          label: label,
          isRegistered: peerChannel.dataChannel(label: "rpc") != nil,
          hasRPCChannel: peerChannel.rpcChannel != nil
        ))
      notified.fulfill()
    }

    let didOpen = MessagingRaceDidOpenBox(
      peerChannel: peerChannel,
      peerConnection: pair.outgoingPeerConnection,
      dataChannel: pair.outgoing)
    DispatchQueue(label: "jp.shiguredo.sora.tests.messagingRace.didOpen.entry").async {
      didOpen()
    }
    let result = XCTWaiter.wait(for: [notified], timeout: 10)
    if result == .timedOut {
      // 以降の後始末で、停止した排他単位を待たないようにする
      hasStuckPath = true
    }
    XCTAssertEqual(
      result, .completed,
      "onOpenDataChannel が 10 秒以内に呼ばれること (deadlock の疑い)")
    guard let observation = observed.get() else {
      return
    }
    XCTAssertEqual(observation.label, "rpc", "通知される label")
    XCTAssertTrue(observation.isRegistered, "通知時点で DataChannel が登録されていること")
    XCTAssertTrue(observation.hasRPCChannel, "通知時点で rpcChannel が設定されていること")
  }

  // MARK: - RPC 経路と redirect の無効化

  /// DataChannel の delegate スレッドからの RPC メッセージ処理 (`handleRPCMessage`) と
  /// `performRPC` の参照取得、および redirect の無効化を複数スレッドから交差させます。
  ///
  /// Thread Sanitizer が報告した「DataChannel の delegate スレッドの `handleRPCMessage` の
  /// 読み取りと、切断処理の `rpcChannel` の nil 代入」と同じ読み書きの組を交差させます。
  func testRPCChannelMessageAndRedirectInvalidationRace() throws {
    let mediaChannel = try makeTestMediaChannel()
    self.mediaChannel = mediaChannel
    let dataChannel = try makeRPCDataChannel(mediaChannel: mediaChannel)
    let box = MessagingRaceBox(mediaChannel: mediaChannel, dataChannel: dataChannel)
    box.register(withRPCChannel: true)
    XCTAssertNotNil(box.currentRPCChannel, "登録直後に rpcChannel が参照できること")

    // 交差の中で RPC メッセージ処理が 3200 回走り、pending が無い応答のログがログ量と
    // 実行時間を支配するため、この test の間だけ SDK のログを止める (前後で復元する)。
    // `.off` では出力 handler も呼ばれないため、handler の退避と復元は不要である。
    let originalLevel = Logger.shared.level
    defer { Logger.shared.level = originalLevel }
    Logger.shared.level = .off

    // pending が無い応答 (JSON-RPC 2.0 の response)
    let rpcResponse = Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)
    let workers = concurrentWorkers
    let operations = operationsPerWorker
    for _ in 0..<rounds {
      DispatchQueue.concurrentPerform(iterations: workers) { index in
        switch index % 4 {
        case 0, 1:
          // DataChannel の delegate スレッドからの RPC メッセージ処理を模す
          for _ in 0..<operations {
            box.handleRPCMessage(rpcResponse)
          }
        case 2:
          // `MediaChannel.performRPC` と同じ参照の読み取りを模す
          for _ in 0..<operations {
            _ = box.currentRPCChannel
          }
        default:
          // 新しい接続の登録と redirect の無効化を模す
          for _ in 0..<operations {
            box.register(withRPCChannel: true)
            box.invalidateMessagingAfterRedirect()
          }
        }
      }
    }

    // 無効化が完了した後は RPCChannel が取り出されて nil になる
    box.register(withRPCChannel: true)
    XCTAssertNotNil(box.currentRPCChannel, "無効化の前に rpcChannel が参照できること")
    box.invalidateMessagingAfterRedirect()
    XCTAssertNil(box.currentRPCChannel, "無効化の完了後に rpcChannel が参照されないこと")
  }

  /// `MediaChannel.rpc` (`performRPC` の共通経路) の実行と redirect の無効化を
  /// 複数の `Task` から交差させます。
  ///
  /// `performRPC` は `rpcChannel` の参照を取り出した後に `RPCChannel` の barrier で pending を
  /// 登録するため、参照の取り出しだけが本 issue の排他単位の対象です。交差の後、無効化が
  /// 完了してから開始した RPC が失敗することを固定します。
  func testRPCAndRedirectInvalidationRace() async throws {
    let mediaChannel = try makeTestMediaChannel()
    self.mediaChannel = mediaChannel
    let dataChannel = try makeRPCDataChannel(mediaChannel: mediaChannel)
    let box = MessagingRaceBox(mediaChannel: mediaChannel, dataChannel: dataChannel)
    box.register(withRPCChannel: true)
    XCTAssertNotNil(box.currentRPCChannel, "登録直後に rpcChannel が参照できること")

    let workers = concurrentWorkers * 2
    let operations = operationsPerWorker
    for _ in 0..<rounds {
      await withTaskGroup(of: Void.self) { group in
        for index in 0..<workers {
          if index.isMultiple(of: 2) {
            group.addTask {
              // `rpcChannel` の参照を取り出す実経路を駆動する。失敗は無効化によるもので、
              // この test の対象外 (参照の読み書きが交差すればよい)
              for _ in 0..<operations {
                _ = try? await box.callRPCAsNotification()
              }
            }
          } else {
            group.addTask {
              for _ in 0..<operations {
                box.register(withRPCChannel: true)
                box.markSwitchedToDataChannel()
                box.invalidateMessagingAfterRedirect()
              }
            }
          }
        }
      }
    }

    // 無効化が完了した後に開始した RPC は失敗する
    box.register(withRPCChannel: true)
    box.invalidateMessagingAfterRedirect()
    // `rpc()` の失敗は DataChannel が OPEN でない場合も同じ `rpcUnavailable` になるため、
    // 参照が取り出されていることと reason の両方で無効化を判別する
    XCTAssertNil(box.currentRPCChannel, "無効化の完了後に rpcChannel が参照されないこと")
    do {
      try await box.callRPCAsNotification()
      XCTFail("無効化の完了後に開始した rpc が失敗すること")
    } catch {
      guard case SoraError.rpcUnavailable(let reason) = error else {
        XCTFail("rpcUnavailable が返ること: \(error)")
        return
      }
      XCTAssertEqual(
        reason, "rpc channel is not available",
        "無効化済みの rpcChannel が参照されないこと (DataChannel が OPEN でない場合と区別する)")
    }
  }

  /// 切断の実経路 (`PeerChannel.disconnect` → `basicDisconnect`) が呼ぶ `takeRPCChannel()` と、
  /// DataChannel の delegate スレッドからの `handleRPCMessage` を交差させます。
  ///
  /// Thread Sanitizer が報告した「DataChannel の delegate スレッドの `handleRPCMessage` の
  /// 読み取りと、`basicDisconnect` の `rpcChannel` の nil 代入」と同じ読み書きの組を、
  /// redirect ではなく切断の実経路で交差させます。切断は 1 つの `PeerChannel` に対して
  /// 1 回だけ受理されるため、並行する読み取りの途中で 1 回だけ呼びます。
  func testRPCMessageAndDisconnectRace() throws {
    // 切断経路でカメラ停止などの非同期 cleanup を起こさないよう recvonly で構築する
    // (`ConcurrencyStressTests` と同じ方針)。
    let mediaChannel = try makeRecvonlyTestMediaChannel()
    self.mediaChannel = mediaChannel
    let dataChannel = try makeRPCDataChannel(mediaChannel: mediaChannel)
    let box = MessagingRaceBox(mediaChannel: mediaChannel, dataChannel: dataChannel)
    box.register(withRPCChannel: true)
    XCTAssertNotNil(box.currentRPCChannel, "登録直後に rpcChannel が参照できること")

    // ログを止める理由は testRPCChannelMessageAndRedirectInvalidationRace と同じ
    let originalLevel = Logger.shared.level
    defer { Logger.shared.level = originalLevel }
    Logger.shared.level = .off

    let rpcResponse = Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)
    let workers = concurrentWorkers
    let operations = operationsPerWorker
    // 読み取りが並行して走っている間に切断する位置
    let disconnectAt = operations / 2
    DispatchQueue.concurrentPerform(iterations: workers) { index in
      for operation in 0..<operations {
        if index == 0, operation == disconnectAt {
          // 切断の実経路 (basicDisconnect が takeRPCChannel で rpcChannel を nil にする)
          box.disconnect()
        }
        box.handleRPCMessage(rpcResponse)
      }
    }

    XCTAssertNil(box.currentRPCChannel, "切断後 (takeRPCChannel 後) に rpcChannel が参照されないこと")
  }

  // MARK: - 排他区間の中から利用者の handler を呼ばないこと

  /// `sendMessage` の送信ログの出力中に、利用者の出力 handler から同じ `sendMessage` を
  /// 呼んでも deadlock しないことを確認します。
  ///
  /// 送信ログは排他単位の外で出す契約です。区間の中で `Logger` を呼ぶ実装に戻すと、
  /// 出力 handler からの再入が同じ非再帰ロックを待って停止します
  /// (`LoggerCallUnderLockTests` と同じ観点を送信経路へ広げた回帰テスト)。
  func testSendMessageFromOutputHandlerDoesNotDeadlock() throws {
    let mediaChannel = try makeTestMediaChannel()
    self.mediaChannel = mediaChannel
    let peerChannel = mediaChannel.peerChannel
    let pair = try makeOpenDataChannelPair(mediaChannel: mediaChannel, label: "#spam")
    let box = MessagingRaceBox(mediaChannel: mediaChannel, dataChannel: pair.sendSide)
    box.register()
    box.markSwitchedToDataChannel()

    // 前提: 送信が実際に試行される (OPEN な DataChannel が登録されている) こと。
    // 前提が崩れた場合は deadlock ではなく前提の失敗として検出する。
    let registered = try XCTUnwrap(
      peerChannel.dataChannel(label: "#spam"), "送信対象の DataChannel が登録されていること")
    XCTAssertEqual(registered.readyState, .open, "送信対象の DataChannel が OPEN であること")

    let originalLevel = Logger.shared.level
    let originalGroups = Logger.shared.groups
    let originalHandler = Logger.shared.onOutputHandler
    defer {
      Logger.shared.onOutputHandler = originalHandler
      Logger.shared.level = originalLevel
      Logger.shared.groups = originalGroups
    }
    Logger.shared.level = .debug
    Logger.shared.groups = [.channels]

    let limiter = LoggerCallUnderLockReentrancyLimiter()
    let reentered = expectation(description: "出力 handler から sendMessage が戻ること")
    Logger.shared.onOutputHandler = { log in
      // 送信ログだけを対象にする (他の経路のログで再入すると、別の排他を検証してしまう)
      guard log.message.contains("send(_:): label => #spam") else {
        return
      }
      guard limiter.consume() else {
        return
      }
      // 排他区間を保持したまま Logger を呼ぶ実装だと、ここで同じ lock を待って停止する
      _ = box.sendMessage(Data([0x01]))
      reentered.fulfill()
    }

    // deadlock するとテストスレッドが停止するため、入口の呼び出しは専用 queue から行い、
    // テストスレッドは expectation を待つだけにする (`LoggerCallUnderLockTests` と同じ方針)
    DispatchQueue(label: "jp.shiguredo.sora.tests.messagingRace.outputHandler.entry")
      .async {
        _ = box.sendMessage(Data([0x01]))
      }
    let result = XCTWaiter.wait(for: [reentered], timeout: 5)
    if result == .timedOut {
      // 以降の後始末で、停止した排他単位を待たないようにする
      hasStuckPath = true
    }
    XCTAssertEqual(
      result, .completed,
      "出力 handler からの再入が 5 秒以内に戻ること (deadlock の疑い)")
  }

  // MARK: - ヘルパー

  /// ローカル接続した 2 つの実 `RTCPeerConnection` に externally negotiated な DataChannel を
  /// 作り、両側が OPEN になるまで待ちます。
  ///
  /// 交渉を待たずに両側の DataChannel を参照できるよう、同じ `channelId` を使います
  /// (`DataChannelStatsSendTests` と同じ構成)。STUN / TURN は使わずローカル候補だけで接続します。
  ///
  /// - Returns: `sendSide` は `peerChannel` に登録して送信に使う `DataChannel`、`outgoing` は
  ///   その native channel (送信側)、`incoming` は対向の native channel (受信の観測側)、
  ///   `outgoingPeerConnection` は `outgoing` を所有する `RTCPeerConnection`
  private func makeOpenDataChannelPair(
    mediaChannel: MediaChannel,
    label: String,
    compress: Bool = false
  ) throws -> (
    sendSide: DataChannel, outgoing: RTCDataChannel, incoming: RTCDataChannel,
    outgoingPeerConnection: RTCPeerConnection
  ) {
    let peerChannel = mediaChannel.peerChannel
    let factory = peerChannel.nativePeerChannelFactory
    let outgoingPeerConnection = try makeTestPeerConnection(factory: factory)
    let incomingPeerConnection = try makeTestPeerConnection(factory: factory)
    peerConnections.append(contentsOf: [outgoingPeerConnection, incomingPeerConnection])

    let configuration = RTCDataChannelConfiguration()
    configuration.isNegotiated = true
    configuration.channelId = 1
    let outgoing = try XCTUnwrap(
      outgoingPeerConnection.dataChannel(forLabel: label, configuration: configuration),
      "送信側の DataChannel を生成できること")
    let incoming = try XCTUnwrap(
      incomingPeerConnection.dataChannel(forLabel: label, configuration: configuration),
      "受信側の DataChannel を生成できること")
    nativeDataChannels.append(contentsOf: [outgoing, incoming])

    try connectLocalPair(outgoingPeerConnection, incomingPeerConnection)

    let opened = expectation(
      for: NSPredicate { _, _ in
        outgoing.readyState == .open && incoming.readyState == .open
      }, evaluatedWith: nil)
    wait(for: [opened], timeout: 20)

    // generation を一致させないことで、テスト終了時に届く非同期の状態通知から
    // PeerChannel.disconnect が呼ばれないようにする (`DataChannelNotificationTests` と同じ方針)
    let sendSide = DataChannel(
      dataChannel: outgoing,
      compress: compress,
      mediaChannel: mediaChannel,
      peerChannel: peerChannel,
      generation: peerChannel.dataChannelGeneration + 1)
    return (sendSide, outgoing, incoming, outgoingPeerConnection)
  }

  /// 交渉を行わない実 `RTCDataChannel` から `rpc` ラベルの `DataChannel` を作ります。
  ///
  /// `readyState` は connecting のままですが、RPC 経路が参照する `DataChannel` と
  /// `RPCChannel` は実物です (参照の読み書きの交差だけを検証するため交渉は不要)。
  private func makeRPCDataChannel(mediaChannel: MediaChannel) throws -> DataChannel {
    let peerChannel = mediaChannel.peerChannel
    let peerConnection = try makeTestPeerConnection(
      factory: peerChannel.nativePeerChannelFactory)
    peerConnections.append(peerConnection)
    let nativeDataChannel = try makeTestDataChannel(peerConnection: peerConnection, label: "rpc")
    nativeDataChannels.append(nativeDataChannel)
    // 状態通知から PeerChannel.disconnect が呼ばれないようにする (generation を一致させない)
    return DataChannel(
      dataChannel: nativeDataChannel,
      compress: false,
      mediaChannel: mediaChannel,
      peerChannel: peerChannel,
      generation: peerChannel.dataChannelGeneration + 1)
  }

  /// 切断経路でカメラ停止などの非同期 cleanup を起こさない recvonly の `MediaChannel` を作ります
  /// (`ConcurrencyStressTests` と同じ方針)。
  private func makeRecvonlyTestMediaChannel() throws -> MediaChannel {
    var configuration = makeTestConfiguration()
    configuration.role = .recvonly
    return try MediaChannel(configuration: configuration)
  }

  /// 2 つの `RTCPeerConnection` をローカルの候補だけで接続します。
  ///
  /// candidate を SDP に含めてから相手へ渡し、trickle ICE の通知実装を不要にします。
  private func connectLocalPair(
    _ outgoing: RTCPeerConnection, _ incoming: RTCPeerConnection
  ) throws {
    try setDescription(try description(peer: outgoing, answer: false), peer: outgoing, local: true)
    waitForCandidates(peer: outgoing)
    try setDescription(try XCTUnwrap(outgoing.localDescription), peer: incoming, local: false)
    try setDescription(
      try description(peer: incoming, answer: true), peer: incoming, local: true)
    waitForCandidates(peer: incoming)
    try setDescription(try XCTUnwrap(incoming.localDescription), peer: outgoing, local: false)
  }

  private func description(
    peer: RTCPeerConnection, answer: Bool
  ) throws -> RTCSessionDescription {
    let completed = expectation(description: "SDP を生成できること")
    let result = MessagingRaceLockedValue<RTCSessionDescription>()
    let callback: @Sendable (RTCSessionDescription?, Error?) -> Void = { description, error in
      XCTAssertNil(error)
      if let description {
        result.set(description)
      }
      completed.fulfill()
    }
    let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    if answer {
      peer.answer(for: constraints, completionHandler: callback)
    } else {
      peer.offer(for: constraints, completionHandler: callback)
    }
    wait(for: [completed], timeout: 10)
    return try XCTUnwrap(result.get(), "SDP を取得できること")
  }

  private func setDescription(
    _ description: RTCSessionDescription, peer: RTCPeerConnection, local: Bool
  ) throws {
    let completed = expectation(description: "SDP を適用できること")
    let failure = MessagingRaceLockedValue<Error>()
    let callback: @Sendable (Error?) -> Void = { error in
      if let error {
        failure.set(error)
      }
      completed.fulfill()
    }
    if local {
      peer.setLocalDescription(description, completionHandler: callback)
    } else {
      peer.setRemoteDescription(description, completionHandler: callback)
    }
    wait(for: [completed], timeout: 10)
    if let error = failure.get() {
      throw error
    }
  }

  private func waitForCandidates(peer: RTCPeerConnection) {
    let gathered = expectation(
      for: NSPredicate { _, _ in peer.iceGatheringState == .complete }, evaluatedWith: nil)
    wait(for: [gathered], timeout: 20)
  }

  /// `sendMessage` が返した `SoraError.messagingError` の reason を取り出します。
  private func messagingErrorReason(_ error: Error?) throws -> String {
    guard let error else {
      XCTFail("sendMessage がエラーを返すこと")
      throw MessagingRaceUnexpectedState()
    }
    guard case SoraError.messagingError(let reason) = error else {
      XCTFail("messagingError が返ること: \(error)")
      throw MessagingRaceUnexpectedState()
    }
    return reason
  }
}

/// テストの前提が崩れたときに、`XCTFail` の後で呼び出し元へ戻るために投げるエラーです。
private struct MessagingRaceUnexpectedState: Error {}
