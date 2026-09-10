import XCTest

@testable @preconcurrency import Sora

/// DataChannel messaging 送受信と stats 検証テスト
final class MessagingE2ETests: E2ETestBase {
  /// メッセージング用ラベル (dataChannels の払い出しと検証で共通)
  private let messagingLabel = "#spam"

  /// sendrecv 2 台が同一チャンネルに接続し、DataChannel 経由でメッセージを送受信できることと、
  /// getStats で対象ラベルの DataChannel stats を確認できることを検証する
  func testSendrecvDataChannelMessaging() throws {
    // テスト固有の一意なチャンネル ID を生成する (残留接続との混在を防ぐ)
    let channelId = buildChannelId(unique: true)

    // client1 → client2 と client2 → client1 に送信するメッセージ
    // (受信確認はハンドラ内でこの値との一致で判定する)
    guard
      let message1 = UUID().uuidString.data(using: .utf8),
      let message2 = UUID().uuidString.data(using: .utf8)
    else {
      XCTFail("メッセージデータの生成に失敗した")
      return
    }

    // 接続完了・switched 受信・メッセージング用ラベルの OPEN・メッセージ受信・
    // DataChannel stats 確認を待つ expectation
    let connect1Expectation = self.expectation(description: "client1 の接続が完了すること")
    let connect2Expectation = self.expectation(description: "client2 の接続が完了すること")
    let switched1Expectation = self.expectation(description: "client1 が switched メッセージを受信すること")
    let switched2Expectation = self.expectation(description: "client2 が switched メッセージを受信すること")
    let dataChannelOpened1Expectation = self.expectation(
      description: "client1 のメッセージング用ラベルの DataChannel が OPEN すること")
    let dataChannelOpened2Expectation = self.expectation(
      description: "client2 のメッセージング用ラベルの DataChannel が OPEN すること")
    let messageReceived2Expectation = self.expectation(
      description: "client2 が client1 のメッセージを受信すること")
    let messageReceived1Expectation = self.expectation(
      description: "client1 が client2 のメッセージを受信すること")
    let statsExpectation = self.expectation(description: "DataChannel stats を確認できること")

    // 接続したチャンネルを保持する (切断に使用する)
    var channel1: MediaChannel?
    var channel2: MediaChannel?
    // offer に data_channels フィールドが含まれるかとメッセージング用ラベルが含まれるかを保持する
    var offerContainsDataChannels = false
    var offerContainsMessagingLabel = false
    // expectation の二重 fulfill (XCTest の API violation) を防ぐためのフラグ。
    // ハンドラ経由の fulfill と後始末 (XCTSkip / エラー分岐) の fulfill が重複すると、
    // "API violation - multiple calls made to fulfill" としてテスト失敗になるため
    var switched1ExpectationFulfilled = false
    var switched2ExpectationFulfilled = false
    var dataChannelOpened1ExpectationFulfilled = false
    var dataChannelOpened2ExpectationFulfilled = false
    var messageReceived1ExpectationFulfilled = false
    var messageReceived2ExpectationFulfilled = false

    // sendrecv 用の Configuration (client1 / client2 は同一チャンネル・同一設定)
    var config1 = try buildConfiguration(role: .sendrecv)
    config1.channelId = channelId
    config1.dataChannelSignaling = true
    config1.ignoreDisconnectWebSocket = true
    config1.videoEnabled = false
    config1.audioEnabled = false
    config1.initialCameraEnabled = false
    // メッセージング用ラベルを払い出す
    // (direction は Sora の data_channels 仕様の必須項目)
    config1.dataChannels = [
      ["label": messagingLabel, "direction": "sendrecv", "compress": false]
    ]

    var config2 = try buildConfiguration(role: .sendrecv)
    config2.channelId = channelId
    config2.dataChannelSignaling = true
    config2.ignoreDisconnectWebSocket = true
    config2.videoEnabled = false
    config2.audioEnabled = false
    config2.initialCameraEnabled = false
    config2.dataChannels = [
      ["label": messagingLabel, "direction": "sendrecv", "compress": false]
    ]

    // ハンドラは connect 呼び出しより前に登録する (switched は接続完了より先に到着し得る)
    // ハンドラは WebSocket 受信スレッドと DataChannel の delegate スレッドから呼ばれるため、
    // 共有状態の更新は main queue に束ねる
    config1.mediaChannelHandlers.onReceiveSignalingJSON = { json in
      DispatchQueue.main.async {
        guard let data = json.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
          return
        }
        // offer に data_channels フィールドが含まれるかを記録する (SDK と同じキャスト判定)
        if dict["type"] as? String == "offer", dict["data_channels"] is [Any] {
          offerContainsDataChannels = true
        }
        // 払い出したメッセージング用ラベル (#spam) が offer に含まれるかを記録する
        if dict["type"] as? String == "offer",
          let dataChannels = dict["data_channels"] as? [[String: Any]]
        {
          if dataChannels.contains(where: { ($0["label"] as? String) == self.messagingLabel }) {
            offerContainsMessagingLabel = true
          }
        }
        // type: "switched" メッセージを受信したことを記録する
        if dict["type"] as? String == "switched" {
          // 後始末 (XCTSkip / エラー分岐) での fulfill と重複しないよう、一度だけ fulfill する
          if !switched1ExpectationFulfilled {
            switched1ExpectationFulfilled = true
            switched1Expectation.fulfill()
          }
        }
      }
    }
    // client1 のメッセージング用ラベル (#spam) の OPEN を記録する
    config1.mediaChannelHandlers.onDataChannelOpened = { _, label in
      DispatchQueue.main.async {
        if label == self.messagingLabel {
          // 後始末 (XCTSkip / エラー分岐) での fulfill と重複しないよう、一度だけ fulfill する
          if !dataChannelOpened1ExpectationFulfilled {
            dataChannelOpened1ExpectationFulfilled = true
            dataChannelOpened1Expectation.fulfill()
          }
        }
      }
    }
    // client1 が受信したメッセージを検証する
    // (Sora が送信者へメッセージをエコーするかは実装依存のため、期待メッセージ (message2) との
    // 一致で判定する)
    config1.mediaChannelHandlers.onDataChannelMessage = { _, label, data in
      DispatchQueue.main.async {
        guard label == self.messagingLabel, data == message2 else { return }
        // 後始末 (XCTSkip / エラー分岐) での fulfill と重複しないよう、一度だけ fulfill する
        if !messageReceived1ExpectationFulfilled {
          messageReceived1ExpectationFulfilled = true
          messageReceived1Expectation.fulfill()
        }
      }
    }
    // client2 は switched 受信とメッセージング用ラベルの OPEN を記録する
    // (offer の data_channels 判定は client1 のハンドラで実施済みのため省略する)
    config2.mediaChannelHandlers.onReceiveSignalingJSON = { json in
      DispatchQueue.main.async {
        guard let data = json.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
          return
        }
        // type: "switched" メッセージを受信したことを記録する
        if dict["type"] as? String == "switched" {
          // 後始末 (XCTSkip / エラー分岐) での fulfill と重複しないよう、一度だけ fulfill する
          if !switched2ExpectationFulfilled {
            switched2ExpectationFulfilled = true
            switched2Expectation.fulfill()
          }
        }
      }
    }
    // client2 のメッセージング用ラベル (#spam) の OPEN を記録する
    config2.mediaChannelHandlers.onDataChannelOpened = { _, label in
      DispatchQueue.main.async {
        if label == self.messagingLabel {
          // 後始末 (XCTSkip / エラー分岐) での fulfill と重複しないよう、一度だけ fulfill する
          if !dataChannelOpened2ExpectationFulfilled {
            dataChannelOpened2ExpectationFulfilled = true
            dataChannelOpened2Expectation.fulfill()
          }
        }
      }
    }
    // client2 が受信したメッセージを検証する (期待メッセージ (message1) との一致で判定する)
    config2.mediaChannelHandlers.onDataChannelMessage = { _, label, data in
      DispatchQueue.main.async {
        guard label == self.messagingLabel, data == message1 else { return }
        // 後始末 (XCTSkip / エラー分岐) での fulfill と重複しないよう、一度だけ fulfill する
        if !messageReceived2ExpectationFulfilled {
          messageReceived2ExpectationFulfilled = true
          messageReceived2Expectation.fulfill()
        }
      }
    }

    // client1 を接続し、接続完了後に client2 を接続する (直列)
    // connect コールバックは実行キューが固定されていないため、共有状態の更新と
    // 後続処理は main queue に束ねる
    _ = sora?.connect(configuration: config1) { [self] mediaChannel, error in
      DispatchQueue.main.async {
        if let error {
          XCTFail("client1 の接続に失敗した : \(error)")
          connect1Expectation.fulfill()
          return
        }
        guard let connectedChannel = mediaChannel else {
          XCTFail("client1 のメディアチャネルが nil")
          connect1Expectation.fulfill()
          return
        }
        channel1 = connectedChannel
        connect1Expectation.fulfill()

        // client2 を接続する
        _ = self.sora?.connect(configuration: config2) { mediaChannel2, error2 in
          DispatchQueue.main.async {
            if let error2 {
              XCTFail("client2 の接続に失敗した : \(error2)")
              connect2Expectation.fulfill()
              return
            }
            guard let connectedChannel2 = mediaChannel2 else {
              XCTFail("client2 のメディアチャネルが nil")
              connect2Expectation.fulfill()
              return
            }
            channel2 = connectedChannel2
            connect2Expectation.fulfill()
          }
        }
      }
    }

    // client1 の接続完了を待つ
    wait(for: [connect1Expectation], timeout: 35)
    guard let channel1 else {
      // 後始末: 接続済みチャンネルの切断 (client2 は接続を開始していない)
      disconnectAll(channels: [channel1, channel2])
      // 未 wait の expectation を wait 済みにして、テスト終了時の unwaited expectation
      // 報告を防ぐ。XCTWaiter.wait はタイムアウト (0 秒) でも failure を報告しない。
      // 接続失敗時は SDK の接続が終了しているため、以降の fulfill は発生しない
      _ = XCTWaiter.wait(
        for: [
          connect2Expectation, switched1Expectation, switched2Expectation,
          dataChannelOpened1Expectation, dataChannelOpened2Expectation,
          messageReceived1Expectation, messageReceived2Expectation, statsExpectation,
        ],
        timeout: 0)
      return
    }
    // client2 の接続完了を待つ
    wait(for: [connect2Expectation], timeout: 35)
    guard let channel2 else {
      // 後始末: 接続済みチャンネルの切断
      disconnectAll(channels: [channel1, channel2])
      // 未 wait の expectation を wait 済みにして、テスト終了時の unwaited expectation
      // 報告を防ぐ
      _ = XCTWaiter.wait(
        for: [
          switched1Expectation, switched2Expectation,
          dataChannelOpened1Expectation, dataChannelOpened2Expectation,
          messageReceived1Expectation, messageReceived2Expectation, statsExpectation,
        ],
        timeout: 0)
      return
    }

    // offer に data_channels フィールドが含まれるかを確認する
    // (Sora サーバーが DataChannel シグナリング未対応の場合は XCTSkip でスキップする)
    // offer に data_channels フィールドが含まれない場合 (DataChannel シグナリング未対応) と、
    // 払い出したメッセージング用ラベル (#spam) が offer に含まれない場合は、
    // DataChannel のメッセージング検証ができないため XCTSkip でスキップする
    guard offerContainsDataChannels, offerContainsMessagingLabel else {
      // 残留チャンネルを残さないよう、後始末を実行してからスキップする
      disconnectAll(channels: [channel1, channel2])
      // XCTSkip では expectation のチェックが行われないため、fulfill は不要
      if !offerContainsDataChannels {
        throw XCTSkip("Sora サーバーが DataChannel シグナリング未対応のためスキップします")
      }
      throw XCTSkip("Sora サーバーがメッセージング用ラベルを払い出さないためスキップします")
    }

    // 送信準備 (両クライアントの switched 受信とメッセージング用ラベルの OPEN) を待つ。
    // sendMessage は switchedToDataChannel ゲート (type: "switched" 受信時のみ true) があるため、
    // onDataChannelOpened だけでは "DataChannel is not open yet" で失敗する。
    // また、受信側の DataChannel が OPEN する前に送ったメッセージは Sora が中継できないため、
    // 両クライアントの両条件を 1 回の wait で待つ
    let readinessResult = XCTWaiter.wait(
      for: [
        switched1Expectation, switched2Expectation,
        dataChannelOpened1Expectation, dataChannelOpened2Expectation,
      ],
      timeout: 10)
    guard readinessResult == .completed else {
      XCTFail("送信準備 (switched 受信と DataChannel OPEN) が完了しなかった")
      disconnectAll(channels: [channel1, channel2])
      // 未 wait の expectation を wait 済みにして、テスト終了時の unwaited expectation
      // 報告を防ぐ
      _ = XCTWaiter.wait(
        for: [messageReceived1Expectation, messageReceived2Expectation, statsExpectation],
        timeout: 0)
      return
    }

    // client1 → client2 にメッセージを送信する
    XCTAssertNil(channel1.sendMessage(label: messagingLabel, data: message1), "メッセージの送信が成功すること")
    // client2 での受信を待つ
    wait(for: [messageReceived2Expectation], timeout: 10)

    // client2 → client1 にメッセージを送信する
    XCTAssertNil(channel2.sendMessage(label: messagingLabel, data: message2), "メッセージの送信が成功すること")
    // client1 での受信を待つ
    wait(for: [messageReceived1Expectation], timeout: 10)

    // 両チャンネルの getStats を取得し、対象ラベル (#spam) の DataChannel stats を確認する。
    // stats 集計の遅延に備え、リトライ付きで検証する
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
      self.verifyDataChannelStats(
        channel1: channel1,
        channel2: channel2,
        attempt: 1,
        maxAttempts: 3,
        expectation: statsExpectation)
    }
    wait(for: [statsExpectation], timeout: 30)

    // 後始末: チャンネルを切断する
    for channel in [channel1, channel2] {
      disconnectAndVerify(channel: channel)
    }
  }

  // MARK: - 検証ヘルパー

  /// 両チャンネルの DataChannel stats を検証する (5 秒間隔で最大 maxAttempts 回リトライする)
  ///
  /// このヘルパーは main queue 上で実行される。2 本の getStats コールバックは実行キューが
  /// 固定されていないため、completedCount / stats1 / stats2 / statsFailures の更新は
  /// main queue に束ねてデータ競合を防ぐ。
  private func verifyDataChannelStats(
    channel1: MediaChannel,
    channel2: MediaChannel,
    attempt: Int,
    maxAttempts: Int,
    expectation: XCTestExpectation
  ) {
    var completedCount = 0
    var stats1: Statistics?
    var stats2: Statistics?
    // getStats の失敗理由を保持する (一時的な failure は次のリトライで回復し得るため、
    // 上限到達時にこの内容を診断メッセージとして出力する)
    var statsFailures: [String] = []

    // 両チャンネルの getStats の完了を待ち合わせる (カウンタ方式)
    let check: () -> Void = {
      completedCount += 1
      guard completedCount == 2 else { return }

      // 両チャンネルの getStats が成功し、両方の DataChannel stats が確認できた場合は成功
      if statsFailures.isEmpty, let stats1, let stats2 {
        let ok1 = self.hasDataChannelStats(stats: stats1)
        let ok2 = self.hasDataChannelStats(stats: stats2)
        if ok1 && ok2 {
          expectation.fulfill()
          return
        }
      }

      // getStats の failure は getStats 実行中の接続状態の遷移 (切断・チャンネル再生成等) が
      // 原因で発生し得るため、DataChannel stats 未達と同様にリトライする。上限に達した場合は
      // 失敗とする
      if attempt >= maxAttempts {
        if !statsFailures.isEmpty {
          XCTFail("getStats に失敗した : \(statsFailures.joined(separator: "、"))")
        } else {
          XCTFail("\(maxAttempts) 回試行しても両チャンネルの DataChannel stats を確認できなかった")
        }
        expectation.fulfill()
      } else {
        // stats 集計の遅延に備え、5 秒後に再試行する
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
          self.verifyDataChannelStats(
            channel1: channel1,
            channel2: channel2,
            attempt: attempt + 1,
            maxAttempts: maxAttempts,
            expectation: expectation)
        }
      }
    }

    channel1.getStats { result in
      DispatchQueue.main.async {
        switch result {
        case .success(let stats):
          stats1 = stats
          check()
        case .failure(let error):
          statsFailures.append("client1 の getStats に失敗した (\(error))")
          check()
        }
      }
    }
    channel2.getStats { result in
      DispatchQueue.main.async {
        switch result {
        case .success(let stats):
          stats2 = stats
          check()
        case .failure(let error):
          statsFailures.append("client2 の getStats に失敗した (\(error))")
          check()
        }
      }
    }
  }

  /// 対象ラベルの DataChannel stats が 4 項目すべて 0 より大きいかを確認する
  private func hasDataChannelStats(stats: Statistics) -> Bool {
    let dataChannel = stats.entries.first {
      $0.type == "data-channel"
        && ($0.values["label"] as? String) == self.messagingLabel
    }
    guard let dataChannel else {
      return false
    }
    let bytesSent = dataChannel.values["bytesSent"] as? NSNumber
    let bytesReceived = dataChannel.values["bytesReceived"] as? NSNumber
    let messagesSent = dataChannel.values["messagesSent"] as? NSNumber
    let messagesReceived = dataChannel.values["messagesReceived"] as? NSNumber
    return (bytesSent?.intValue ?? 0) > 0
      && (bytesReceived?.intValue ?? 0) > 0
      && (messagesSent?.intValue ?? 0) > 0
      && (messagesReceived?.intValue ?? 0) > 0
  }
}
