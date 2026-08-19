import XCTest

@testable import Sora

/// MediaChannel の DataChannel 一括通知 (onDataChannel) の判定ロジックのテスト
final class DataChannelNotificationTests: XCTestCase {

  // MARK: - shouldNotifyDataChannelAvailable のテスト

  // メッセージング用ラベルが存在しない場合は発火しないことを確認する。
  // (メッセージング用ラベルが存在しない接続では onDataChannel は発火しない)
  func testShouldNotifyWithNoMessagingLabels() {
    let result = MediaChannel.shouldNotifyDataChannelAvailable(
      messagingLabels: [],
      openedLabels: ["signaling", "#spam"],
      notified: false)
    XCTAssertFalse(result, "メッセージング用ラベルが存在しない場合は発火しないこと")
  }

  // メッセージング用ラベルの一部が OPEN の場合は発火しないことを確認する。
  // (すべてのメッセージング用ラベルが OPEN になった時点で発火する)
  func testShouldNotifyWithPartiallyOpenedLabels() {
    let result = MediaChannel.shouldNotifyDataChannelAvailable(
      messagingLabels: ["#spam", "#egg"],
      openedLabels: ["#spam"],
      notified: false)
    XCTAssertFalse(result, "一部のメッセージング用ラベルが OPEN の場合は発火しないこと")
  }

  // すべてのメッセージング用ラベルが OPEN になった場合に発火することを確認する。
  // (OPEN 済みのラベル集合にメッセージング用ラベル以外が含まれていても判定に影響しない)
  func testShouldNotifyWithAllOpenedLabels() {
    let result = MediaChannel.shouldNotifyDataChannelAvailable(
      messagingLabels: ["#spam", "#egg"],
      openedLabels: ["signaling", "#spam", "#egg"],
      notified: false)
    XCTAssertTrue(result, "すべてのメッセージング用ラベルが OPEN の場合は発火すること")
  }

  // 一括通知済みの場合は発火しないことを確認する (二重発火の防止)。
  // (onDataChannel の発火は 1 回のみであり、switched 受信時に発火が復活した場合も
  // 2 回目の発火はこの判定で抑止される)
  func testShouldNotifyAfterNotified() {
    let result = MediaChannel.shouldNotifyDataChannelAvailable(
      messagingLabels: ["#spam"],
      openedLabels: ["#spam"],
      notified: true)
    XCTAssertFalse(result, "一括通知済みの場合は発火しないこと")
  }

  // 一括通知済みフラグ (notified) が false の場合は、全メッセージング用ラベルが OPEN なら
  // 発火できることを確認する。
  // (notified == true の場合は testShouldNotifyAfterNotified で発火しないことを確認済み。
  // リセットの状態遷移自体 (onDataChannelNotified の true → false) は
  // resetDataChannelNotificationState が行うため、この純粋関数のテストでは検証しない)
  func testShouldNotifyWhenNotNotified() {
    let result = MediaChannel.shouldNotifyDataChannelAvailable(
      messagingLabels: ["#spam"],
      openedLabels: ["#spam"],
      notified: false)
    XCTAssertTrue(result, "notified が false の場合は発火できること")
  }

  // MARK: - messagingLabels(from:) のテスト

  // offer の data_channels から # 始まりのラベルだけを抽出することを確認する
  func testMessagingLabelsExtractsHashPrefixedLabels() {
    let dataChannels: [[String: Any]] = [
      ["label": "signaling"],
      ["label": "#spam"],
      ["label": "stats"],
      ["label": "#egg"],
    ]
    let result = MediaChannel.messagingLabels(from: dataChannels)
    XCTAssertEqual(result, ["#spam", "#egg"], "# 始まりのラベルだけを抽出すること")
  }

  // label キーが欠落した要素は無視することを確認する
  func testMessagingLabelsIgnoresMissingLabel() {
    let dataChannels: [[String: Any]] = [
      ["compress": true],
      ["label": "#spam"],
    ]
    let result = MediaChannel.messagingLabels(from: dataChannels)
    XCTAssertEqual(result, ["#spam"], "label キーが欠落した要素は無視すること")
  }

  // label キーの値が String でない要素は無視することを確認する
  func testMessagingLabelsIgnoresNonStringLabel() {
    let dataChannels: [[String: Any]] = [
      ["label": 123],
      ["label": "#spam"],
    ]
    let result = MediaChannel.messagingLabels(from: dataChannels)
    XCTAssertEqual(result, ["#spam"], "label キーの値が String でない要素は無視すること")
  }

  // メッセージング用ラベルが存在しない場合は空集合を返すことを確認する
  func testMessagingLabelsReturnsEmptySetWhenNoMessagingLabel() {
    let dataChannels: [[String: Any]] = [
      ["label": "signaling"],
      ["label": "stats"],
    ]
    let result = MediaChannel.messagingLabels(from: dataChannels)
    XCTAssertTrue(result.isEmpty, "メッセージング用ラベルが存在しない場合は空集合を返すこと")
  }
}
