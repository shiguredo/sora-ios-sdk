import XCTest

@testable import Sora

/// `MediaChannel` は `Sendable` ではないため、MainActor 隔離のテストから非分離の async API を
/// 呼ぶと送信診断になります。テスト内の利用に限定して参照をこの箱へまとめます。
///
/// この箱は実行文脈を揃えるものではありません。async メソッドは nonisolated のため main actor 上
/// では実行されず、handler は SDK 側の任意の実行文脈から呼ばれます。この箱は可変状態を持たず
/// 参照を保持するだけで、安全性は `MediaChannel` の内部同期に依存します。
private final class StatisticsChannelBox: @unchecked Sendable {
  let channel: MediaChannel

  init(_ channel: MediaChannel) {
    self.channel = channel
  }

  /// snapshot を async 版で取得します。
  func getStatsSnapshot() async throws -> StatisticsSnapshot {
    try await channel.getStatsSnapshot()
  }

  /// snapshot を callback 版で取得します。
  func getStatsSnapshot(handler: @escaping (Result<StatisticsSnapshot, Error>) -> Void) {
    channel.getStatsSnapshot(handler: handler)
  }
}

/// 実 Sora サーバーへ接続して statistics snapshot API を検証する E2E テストです。
///
/// 環境変数 `SORA_SIGNALING_URL` と `TEST_SECRET_KEY` が未設定の場合はスキップされます
/// (`E2ETestBase.buildConfiguration()` の契約)。
final class StatisticsSnapshotE2ETests: E2ETestBase {
  /// E2E テスト用の接続タイムアウト (秒)
  ///
  /// CI の E2E はサーバーの応答が遅い場合があるため、SDK の既定値 (30 秒) より長くします。
  /// SDK の既定値は変更せず、このファイルの Configuration にだけ設定します。
  private let connectionTimeout = 60

  /// 接続待ちのタイムアウト (秒)
  ///
  /// `ConnectionTimer` による `connectionTimeout` の発火を wait の内側で処理し、テスト終了後に
  /// 遅延コールバックが残らないようにします。
  private var connectWaitTimeout: TimeInterval {
    TimeInterval(connectionTimeout + 30)
  }

  /// E2E 用の設定で接続し、接続できたチャンネルを返します。
  ///
  /// 接続 callback は libwebrtc の delegate スレッドから呼ばれるため、`state` の更新は
  /// main queue へ束ねます。接続に失敗した場合は `nil` を返し、残ったチャンネルの切断は
  /// `E2ETestBase.tearDown()` に任せます (`disconnectAll(channels:)` は `wait` を使うため
  /// async テストからは呼びません)。
  ///
  /// 待ち合わせに `wait(for:timeout:)` は使いません。async テストから同期ヘルパー経由で
  /// 呼んだ `wait` は main queue を処理しないため、main queue へ束ねた callback が走らずに
  /// タイムアウトします (`VideoHardMuteRollbackE2ETests` と同じく `fulfillment(of:timeout:)`
  /// を使います)。
  /// - Returns: 接続できたチャンネル。接続に失敗した場合は `nil`
  private func connectAndWait() async throws -> MediaChannel? {
    var config = try buildConfiguration()
    config.connectionTimeout = connectionTimeout

    let connectExpectation = expectation(description: "接続が完了すること")
    var connectedChannel: MediaChannel?
    // 待ち合わせの終了後に発火した callback で assertion を記録しないためのフラグ。
    var waitFinished = false
    _ = sora?.connect(configuration: config) { mediaChannel, error in
      DispatchQueue.main.async {
        guard !waitFinished else { return }
        if let error {
          XCTFail("接続に失敗した: \(error)")
        } else {
          XCTAssertNotNil(mediaChannel, "接続成功時は mediaChannel が渡ること")
          connectedChannel = mediaChannel
        }
        connectExpectation.fulfill()
      }
    }
    await fulfillment(of: [connectExpectation], timeout: connectWaitTimeout)
    waitFinished = true

    return connectedChannel
  }

  /// 実 PeerConnection から snapshot を取得し、元の report が解放された後も値を読めることを
  /// 確認する
  ///
  /// snapshot は完了 block の中で `RTCStatisticsReport` から変換されるため、report の生存には
  /// 依存しません。callback 版と async 版の両方で取得し、実接続では統計エントリーが存在することを
  /// 固定します (エントリーを落とす退行は、ここでの件数と unit テストの件数比較で検出します)。
  /// 2 回の取得は別時刻の report になるため値の一致は比較しません (同一 report での値の比較は
  /// `StatisticsSnapshotTests` が行います)。
  func testGetStatsSnapshotReturnsReadableValues() async throws {
    guard let channel = try await connectAndWait() else {
      return
    }

    let box = StatisticsChannelBox(channel)

    // callback 版
    let callbackExpectation = expectation(description: "callback 版で snapshot を取得できること")
    let observation = StatisticsSnapshotObservation()
    box.getStatsSnapshot { result in
      // handler は `@Sendable` ではないため MainActor 隔離を継承します。handler の中では closure を
      // 呼ばず (`first(where:)` など)、Sendable な箱へ記録するだけにします (WebRTC スレッドから
      // closure を呼ぶと実行時違反になります)。
      observation.record(result)
      callbackExpectation.fulfill()
    }
    await fulfillment(of: [callbackExpectation], timeout: 10)

    guard case .success(let callbackSnapshot) = observation.recordedResult else {
      XCTFail(
        "callback 版で snapshot を取得できること (result: \(String(describing: observation.recordedResult)))"
      )
      return
    }
    XCTAssertEqual(observation.recordedCallCount, 1, "handler が 1 回だけ呼ばれること")
    assertReadableSnapshot(callbackSnapshot, api: "callback 版")

    // async 版
    let asyncSnapshot = try await box.getStatsSnapshot()
    assertReadableSnapshot(asyncSnapshot, api: "async 版")

    await disconnectAndVerify(channel: channel)
  }

  /// チャンネルを切断し、`onDisconnect` が正常切断コードで呼ばれることを確認します。
  ///
  /// 基底クラスの `disconnectAndVerify(channel:timeout:)` は `wait(for:timeout:)` を使うため、
  /// async テストから呼ぶと main queue が処理されずにタイムアウトします (接続と同じ理由)。
  /// `VideoHardMuteRollbackE2ETests` と同じく `fulfillment(of:timeout:)` を使います。
  /// - Parameters:
  ///   - channel: 切断するチャンネル
  ///   - timeout: 切断完了を待つ秒数
  private func disconnectAndVerify(channel: MediaChannel, timeout: TimeInterval = 10) async {
    guard channel.state != .disconnected else {
      return
    }
    let disconnectExpectation = expectation(description: "切断が完了すること")
    // onDisconnect のイベントは main queue に束ねて保持し、検証は待ち合わせの後に行います。
    var disconnectEvent: SoraCloseEvent?
    channel.handlers.onDisconnect = { event in
      DispatchQueue.main.async {
        disconnectEvent = event
        disconnectExpectation.fulfill()
      }
    }
    // シグナリング受信による切断完了が state の確認とハンドラ設定の間に入った場合は、
    // onDisconnect が発火済みのため待ちません。
    guard channel.state != .disconnected else {
      _ = await fulfillment(of: [disconnectExpectation], timeout: 0)
      return
    }
    if channel.state != .disconnecting {
      channel.disconnect(error: nil)
    }
    await fulfillment(of: [disconnectExpectation], timeout: timeout)

    guard let disconnectEvent else {
      return
    }
    if case .ok(let code, _) = disconnectEvent {
      XCTAssertEqual(code, 1000, "正常切断コードであること")
    } else {
      XCTFail("予期しない切断: \(disconnectEvent)")
    }
  }

  /// snapshot が実接続の統計として読めることを確認します。
  /// - Parameters:
  ///   - snapshot: 検証する snapshot
  ///   - api: 失敗メッセージに使う API の名前
  private func assertReadableSnapshot(_ snapshot: StatisticsSnapshot, api: String) {
    XCTAssertGreaterThan(snapshot.timestamp, 0, "\(api): 収集時刻が入ること")
    XCTAssertFalse(snapshot.entries.isEmpty, "\(api): 実接続では統計エントリーがあること")
    for entry in snapshot.entries {
      XCTAssertFalse(entry.id.isEmpty, "\(api): エントリー ID が空でないこと")
      XCTAssertFalse(entry.type.isEmpty, "\(api): 統計種別が空でないこと")
    }
    // 元の report が解放された後も値が読めること (変換後の値を少なくとも 1 つ読む)。
    XCTAssertTrue(
      snapshot.entries.contains { !$0.values.isEmpty },
      "\(api): 統計値が 1 つ以上読めること")
  }
}
