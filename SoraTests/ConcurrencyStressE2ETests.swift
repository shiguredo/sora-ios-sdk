import XCTest

@testable import Sora

// 実 Sora サーバーへ接続する E2E concurrency runtime stress test です。
//
// TSan はデータ競合を確率的にしか検出しないため、接続の生成と終端の経路を scenario を
// 切り替えながら反復します。`xcodebuild test` の 1 回の実行で覆われる接続経路は 1 通りですが、
// 5 iteration で connect / cancel / disconnect / RPC の timeout と cancellation /
// DataChannel の open と close を交差させます。
//
// モックやスタブは使用せず、実 `Sora` / 実 `MediaChannel` / 実 `E2ETestBase` のヘルパーだけを
// 使います。`E2ETestBase` の async な `setUp` / `tearDown` 契約に従います。
//
// iteration 数と timeout の選定理由:
// - 5 iteration は、実 Sora への接続 1 回あたりのコスト (接続から切断完了まで数秒) と、
//   scenario を一巡させることの両方を満たす最小の反復数です。これ以上増やすと job の
//   実行時間が TSan の `timeout-minutes: 60` を圧迫します。
// - 1 iteration の完了待ちは 30 秒です。実 Sora への接続と切断は通常数秒で完了し、
//   30 秒を超える場合はサーバー側または SDK 側の異常として切り分けたい時間です。
// - test 全体の timeout は 300 秒です。5 iteration × 30 秒 + 後始末の余裕を見込んだ値です。
// - iteration の開始と終了、scenario 名、iteration 番号をログへ出します。失敗したときに
//   どの iteration のどの scenario かを切り分けるためです。
//
// redirect はサーバー側の指示で発生しクライアントから任意に起こせないため、この stress の
// scenario には含めません (redirect は既存の `PeerChannelRedirectInvalidationTests` が
// TSan の対象に入ります)。0154 が扱う handler bag の読み書きを並行させる stress も
// 本ファイルの対象に含めません (issue 0119 のスコープ外)。

/// 実 Sora 接続を反復する E2E concurrency runtime stress test です。
final class ConcurrencyStressE2ETests: E2ETestBase {
  /// 1 iteration の完了待ちの上限 (秒)
  private let iterationTimeout: TimeInterval = 30

  /// test 全体の timeout (秒)
  private let totalTimeout: TimeInterval = 300

  /// RPC timeout の検証で使う、通常の応答より短い timeout (秒)
  ///
  /// サーバーが応答する前に timeout の配送経路を通す目的で、通常の RPC 応答時間より短い値を
  /// 使います。この値でも応答が返る場合は、timeout の配送経路を通らずに完了したことになります。
  private let shortRPCTimeout: TimeInterval = 0.001

  /// 繰り返す iteration の数
  private let iterationCount = 5

  /// 実行する scenario の識別子です。
  private enum StressScenario: String {
    /// 接続して DataChannel を開き、切断する
    case connectAndDisconnect = "connect-and-disconnect"

    /// 接続を直ちにキャンセルする
    case immediateCancel = "immediate-cancel"

    /// 接続と切断を繰り返す
    case repeatedConnectAndDisconnect = "repeated-connect-and-disconnect"

    /// RPC の timeout 経路を通す
    case rpcTimeout = "rpc-timeout"

    /// 実行中の RPC をキャンセルする
    case rpcCancellation = "rpc-cancellation"

    /// iteration 番号から scenario を決める
    ///
    /// scenario の選択は iteration 番号だけで決めます (乱数を使わない)。失敗した iteration の
    /// scenario が実行のたびに変わると、切り分けと再現ができなくなるためです。
    static func scenario(forIteration index: Int) -> StressScenario {
      switch index % 5 {
      case 0: return .connectAndDisconnect
      case 1: return .immediateCancel
      case 2: return .repeatedConnectAndDisconnect
      case 3: return .rpcTimeout
      default: return .rpcCancellation
      }
    }
  }

  /// scenario を切り替えながら実 Sora 接続を反復する
  ///
  /// 通常の test と TSan 有効時の両方で成功することを前提とする。TSan でしか通らない test は
  /// 追加しない。iteration の間に接続を残さない (`disconnectAndVerify` / `disconnectAll` で
  /// 後始末し、iteration の終了時に `mediaChannels` が空であることを確認する)。
  func testConnectionStressScenarios() throws {
    // test 全体の timeout を 300 秒にする (XCTest の実行時間の上限)
    self.executionTimeAllowance = totalTimeout

    for index in 0..<iterationCount {
      let scenario = StressScenario.scenario(forIteration: index)
      print(
        "stress iteration \(index + 1)/\(iterationCount) started: scenario=\(scenario.rawValue)")

      switch scenario {
      case .connectAndDisconnect:
        try runConnectAndDisconnectIteration(role: .recvonly)

      case .immediateCancel:
        try runImmediateCancelIteration()

      case .repeatedConnectAndDisconnect:
        for repetition in 0..<3 {
          print(
            "stress iteration \(index + 1) repetition \(repetition + 1)/3: scenario=\(scenario.rawValue)"
          )
          try runConnectAndDisconnectIteration(role: .recvonly)
        }

      case .rpcTimeout:
        try runRPCIteration(shouldCancel: false)

      case .rpcCancellation:
        try runRPCIteration(shouldCancel: true)
      }

      // iteration の間に接続を残さない (各 iteration が自分の接続を切断してから戻る)
      XCTAssertEqual(
        sora?.mediaChannels.count ?? 0, 0,
        "iteration の終了時に接続が残っていないこと: iteration=\(index + 1) scenario=\(scenario.rawValue)")
      print(
        "stress iteration \(index + 1)/\(iterationCount) finished: scenario=\(scenario.rawValue)")
    }
  }

  // MARK: - iteration の実装

  /// 接続の完了を待ち、DataChannel の open を設定したチャンネルを返します。
  ///
  /// `role` だけで接続する scenario で共通に使います。切断は呼び出し側が行います。
  private func connectAndVerifyChannel(role: Role) throws -> MediaChannel {
    var config = try buildConfiguration(role: role)
    // 実カメラと音声入力を起動しない (接続と切断の経路の検証に限定する)。
    // Simulator では受信あり接続の音声入力の初期化が abort するため、音声は無効にする。
    config.initialCameraEnabled = false
    config.audioEnabled = false
    config.videoEnabled = false
    return try connectAndVerifyChannel(configuration: config)
  }

  /// 接続して DataChannel の open を確認し、切断の完了 (正常切断コード 1000) まで待つ iteration です。
  ///
  /// 接続と切断を 1 つの iteration の中で完結させ、iteration の間に接続を残しません。
  private func runConnectAndDisconnectIteration(role: Role) throws {
    // 接続の完了を待ってから、切断の完了を待つ
    let channel = try connectAndVerifyChannel(role: role)
    // disconnectAndVerify は onDisconnect を設定してから切断し、正常切断コードを検証する
    disconnectAndVerify(channel: channel, timeout: iterationTimeout)
  }

  /// connect() の戻り値を直ちにキャンセルする iteration です。
  private func runImmediateCancelIteration() throws {
    var config = try buildConfiguration(role: .sendonly)
    config.initialCameraEnabled = false
    config.audioEnabled = false
    config.videoEnabled = false

    let cancelExpectation = self.expectation(description: "接続キャンセルが完了すること")
    let task = sora?.connect(configuration: config) { _, error in
      // キャンセル成立時は connectionCancelled エラーが通知される。キャンセルと接続失敗が
      // 同時に通知される場合もあるため、成功 (nil) だけを失敗として扱う
      if error == nil {
        XCTFail("キャンセル後に接続成功が通知された")
      }
    }

    // 別の待機処理を挟まず直ちにキャンセルする
    task?.cancel()

    // キャンセル処理が完了するまで待つ
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
      cancelExpectation.fulfill()
    }
    wait(for: [cancelExpectation], timeout: iterationTimeout)

    // キャンセルした接続が mediaChannels に残っていないこと
    XCTAssertEqual(
      sora?.mediaChannels.count ?? 0, 0,
      "キャンセルした接続が mediaChannels に残っていないこと")
    // キャンセル済みの ConnectionTask の state が canceled であること
    XCTAssertEqual(task?.state, .canceled, "キャンセル済みの ConnectionTask の state が canceled であること")
  }

  /// 実 Sora へ接続し、RPC の timeout または cancellation を実行する iteration です。
  private func runRPCIteration(shouldCancel: Bool) throws {
    var config = try buildConfiguration(role: .recvonly)
    // RPC の DataChannel を開くため、DataChannel signaling を有効にする
    config.simulcastEnabled = true
    config.simulcastRequestRid = .r2
    config.dataChannelSignaling = true
    config.ignoreDisconnectWebSocket = true
    config.videoCodec = .vp8
    config.initialCameraEnabled = false
    config.audioEnabled = false
    config.videoEnabled = false

    // RequestSimulcastRid を rpc_methods で許可する (接続前に設定する必要がある)
    struct StressRPCMetadata: Encodable {
      // Sora が受理するキー名に合わせるため、lowerCamelCase の規則を意図的に外す
      // swift-format-ignore: AlwaysUseLowerCamelCase
      let access_token: String
      // swift-format-ignore: AlwaysUseLowerCamelCase
      let rpc_methods: [String]
    }
    let accessToken = try buildJWTAccessToken(
      channelId: config.channelId,
      privateClaims: ["rpc_methods": [RequestSimulcastRid.name]])
    config.signalingConnectMetadata = StressRPCMetadata(
      access_token: accessToken,
      rpc_methods: [RequestSimulcastRid.name])

    let channel = try connectAndVerifyChannel(configuration: config)

    // rpc ラベルの DataChannel が開くまで待つ。接続完了より先に開く場合があるため、
    // 待つ前に `rpcChannel` の有無も確認する
    let rpcOpenedExpectation = self.expectation(description: "rpc ラベルが OPEN すること")
    var rpcOpenedExpectationFulfilled = false
    channel.handlers.onDataChannelOpened = { _, label in
      DispatchQueue.main.async {
        guard label == "rpc", !rpcOpenedExpectationFulfilled else { return }
        rpcOpenedExpectationFulfilled = true
        rpcOpenedExpectation.fulfill()
      }
    }
    if channel.peerChannel.rpcChannel != nil {
      rpcOpenedExpectationFulfilled = true
      rpcOpenedExpectation.fulfill()
    }
    let rpcOpenedResult = XCTWaiter.wait(for: [rpcOpenedExpectation], timeout: iterationTimeout)
    guard rpcOpenedResult == .completed else {
      XCTFail("rpc ラベルが \(iterationTimeout) 秒以内に OPEN すること")
      disconnectAll(channels: [channel])
      throw StressIterationError.rpcChannelUnavailable
    }

    // RPC を実行する。timeout 経路は短い timeout で、cancellation 経路は実行中の Task を
    // キャンセルすることで通す
    try runRPC(channel: channel, shouldCancel: shouldCancel)

    disconnectAll(channels: [channel])
  }

  /// `RequestSimulcastRid` を非同期に実行し、timeout または cancellation の完了を待ちます。
  ///
  /// `MediaChannel` は Sendable ではないため、`Task` の `@Sendable` closure へ直接渡さず、
  /// 参照を保持するだけの box 経由で渡します (`RpcE2ETests` の `RPCChannelBox` と同じ方針)。
  private func runRPC(channel: MediaChannel, shouldCancel: Bool) throws {
    let box = StressRPCChannelBox(channel)
    let completionExpectation = self.expectation(description: "RPC 呼び出しが終端すること")
    var completionExpectationFulfilled = false
    let fulfillCompletion: () -> Void = {
      // 二重 fulfill は XCTest の API violation になるため、一度だけ fulfill する
      DispatchQueue.main.async {
        guard !completionExpectationFulfilled else { return }
        completionExpectationFulfilled = true
        completionExpectation.fulfill()
      }
    }

    let timeout = shouldCancel ? 2.0 : shortRPCTimeout
    let task = Task {
      do {
        let result = try await box.callRequestSimulcastRid(rid: .r2, timeout: timeout)
        let appliedRID = result.map { String(describing: $0.rid) } ?? "nil"
        print("stress rpc completed: cancel=\(shouldCancel) rid=\(appliedRID)")
      } catch {
        // RPC が失敗することは問題ではない。重要なのは RPC が終端する (エラーが返る) こと
        print(
          "stress rpc terminated: cancel=\(shouldCancel) error=\(error.localizedDescription)")
      }
      fulfillCompletion()
    }

    if shouldCancel {
      // RPC が送信された後にキャンセルする
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        task.cancel()
      }
    }

    guard XCTWaiter.wait(for: [completionExpectation], timeout: iterationTimeout) == .completed
    else {
      // 終端しない RPC は pending が残存している可能性が高い
      XCTFail("RPC 呼び出しが \(iterationTimeout) 秒以内に終端すること")
      throw StressIterationError.rpcNotTerminated
    }
  }

  /// 接続設定を受け取り、DataChannel の open の通知を設定して接続の完了を待ちます。
  ///
  /// 接続 handler は main queue とは限らないスレッドから呼ばれるため、共有状態の更新は
  /// main queue に束ねます (`E2ETestBase` を使う各 E2E test と同じ方針)。
  private func connectAndVerifyChannel(configuration: Configuration) throws -> MediaChannel {
    // `mediaChannelHandlers` は参照型のため、`let` のまま handler を設定できる
    // (Configuration 自体を書き換える必要がない)。
    let config = configuration
    // DataChannel の open の通知を設定する。接続より前に設定する
    config.mediaChannelHandlers.onDataChannelOpened = { _, label in
      print("stress datachannel opened: label=\(label)")
    }

    var channel: MediaChannel?
    var connectError: Error?
    let connectExpectation = self.expectation(description: "接続が完了すること")
    _ = sora?.connect(configuration: config) { mediaChannel, error in
      DispatchQueue.main.async {
        channel = mediaChannel
        connectError = error
        connectExpectation.fulfill()
      }
    }

    guard XCTWaiter.wait(for: [connectExpectation], timeout: iterationTimeout) == .completed else {
      XCTFail("接続が \(iterationTimeout) 秒以内に完了すること")
      throw StressIterationError.connectTimeout
    }
    if let connectError {
      XCTFail("接続に失敗した: \(connectError)")
      throw StressIterationError.connectFailed
    }
    guard let connected = channel else {
      XCTFail("接続に成功した場合は mediaChannel が nil でないこと")
      throw StressIterationError.missingChannel
    }
    return connected
  }

  /// iteration の途中で中断した理由です。
  private enum StressIterationError: Error {
    case connectTimeout
    case connectFailed
    case missingChannel
    case rpcChannelUnavailable
    case rpcNotTerminated
  }
}

/// `MediaChannel` の `RPC` 呼び出しを `Task` の `@Sendable` closure へ渡すための box です。
///
/// `MediaChannel` は Sendable ではないため、参照をこの box へまとめて `@Sendable` closure から
/// 触れるようにします。可変状態を持たず、参照を保持するだけです。安全性は `MediaChannel` の
/// 内部同期に依存します (`RpcE2ETests` の `RPCChannelBox` と同じ方針)。
private final class StressRPCChannelBox: @unchecked Sendable {
  private let channel: MediaChannel

  init(_ channel: MediaChannel) {
    self.channel = channel
  }

  /// `RequestSimulcastRid` を timeout 付きで呼び出し、結果を返します。
  func callRequestSimulcastRid(rid: Rid, timeout: TimeInterval) async throws
    -> RequestSimulcastRidResult?
  {
    try await channel.rpc(
      method: RequestSimulcastRid.self,
      params: RequestSimulcastRidParams(rid: rid),
      timeout: timeout)?.result
  }
}
