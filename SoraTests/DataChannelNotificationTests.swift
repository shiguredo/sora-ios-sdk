import WebRTC
import XCTest

@testable import Sora

/// テストの前提が崩れたときに、`XCTFail` の後で呼び出し元へ戻るために投げるエラーです。
private struct UnexpectedState: Error {}

/// MediaChannel の DataChannel 一括通知 (onDataChannel) とメッセージングの判定ロジックのテスト
final class DataChannelNotificationTests: XCTestCase {
  /// 実経路の確認に使う MediaChannel です。
  ///
  /// `RTCPeerConnectionFactory` は PeerConnection より長生きさせる必要があります
  /// (先に解放すると、transceiver の破棄が破棄済みの task queue を参照してクラッシュします)。
  /// `MediaChannel` は自身の `PeerChannel` 経由で factory を保持するため、instance で保持して
  /// テストメソッドのローカル変数より後に解放されるようにします。
  private var mediaChannel: MediaChannel?

  override func tearDown() {
    mediaChannel = nil
    super.tearDown()
  }

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

  // MARK: - sendMessage の error reason のテスト

  // DataChannel が OPEN でない場合に sendMessage(label:data:) が返す error reason の文字列を
  // 実経路で確認する
  //
  // reason の組み立てが formatter を通ることと、sendMessage が live な readyState をそのまま
  // 渡していることを、実 DataChannel の 2 つの状態 (交渉前の connecting と close() 後の closed) で
  // 固定する。
  func testSendMessageReasonUsesFormatter() throws {
    let mediaChannel = try makeTestMediaChannel()
    self.mediaChannel = mediaChannel

    let peerChannel = mediaChannel.peerChannel
    peerChannel.switchedToDataChannel = true

    // RTCPeerConnectionFactory は MediaChannel が保持するものを利用する
    let peerConnection = try makeTestPeerConnection(
      factory: peerChannel.nativePeerChannelFactory)
    let nativeDataChannel = try makeTestDataChannel(peerConnection: peerConnection, label: "#spam")
    // generation を一致させないことで、close() 後に届く非同期の状態通知から
    // PeerChannel.disconnect が呼ばれないようにする (sendMessage は generation を参照しない)
    // 登録は `didOpen` と同じ経路を使う (登録は PeerChannel の排他単位の中で行われる)
    peerChannel.register(
      dataChannel: DataChannel(
        dataChannel: nativeDataChannel,
        compress: false,
        mediaChannel: mediaChannel,
        peerChannel: peerChannel,
        generation: peerChannel.dataChannelGeneration + 1))

    // 交渉前は connecting
    XCTAssertEqual(
      nativeDataChannel.readyState, .connecting, "交渉前の readyState が connecting であること")
    XCTAssertEqual(
      try messagingErrorReason(mediaChannel: mediaChannel),
      "readyState of the DataChannel is not open: label => #spam, readyState => connecting",
      "reason が formatter の文字列になること")

    // close() 後は closed
    //
    // 交渉していない DataChannel の close() は同期的に closed になるため、reason の文字列が
    // readyState に追従すること (固定値ではないこと) を確認できる。
    nativeDataChannel.close()
    XCTAssertEqual(nativeDataChannel.readyState, .closed, "close() 後の readyState が closed であること")
    XCTAssertEqual(
      try messagingErrorReason(mediaChannel: mediaChannel),
      "readyState of the DataChannel is not open: label => #spam, readyState => closed",
      "reason が formatter の文字列になること")
  }

  // label の検証で拒否される sendMessage(label:data:) が返す error reason の文字列を
  // 実経路で確認する
  //
  // 固定できるのは switched の検証が label の検証より先であること、label の検証が
  // DataChannel の有無と readyState の検証より先であること。OPEN でない DataChannel でも
  // 順序まで含めて確認できる。
  func testSendMessageReasonForInvalidAndUnknownLabels() throws {
    let mediaChannel = try makeTestMediaChannel()
    self.mediaChannel = mediaChannel

    let peerChannel = mediaChannel.peerChannel
    peerChannel.switchedToDataChannel = true

    // RTCPeerConnectionFactory は MediaChannel が保持するものを利用する
    let peerConnection = try makeTestPeerConnection(
      factory: peerChannel.nativePeerChannelFactory)
    let nativeDataChannel = try makeTestDataChannel(peerConnection: peerConnection, label: "#spam")
    peerChannel.register(
      dataChannel: DataChannel(
        dataChannel: nativeDataChannel,
        compress: false,
        mediaChannel: mediaChannel,
        peerChannel: peerChannel,
        generation: peerChannel.dataChannelGeneration + 1))
    defer {
      // close() 後に届く非同期の状態通知から PeerChannel.disconnect が呼ばれないようにする
      nativeDataChannel.delegate = nil
    }

    // `#` で始まらない label (空文字を含む) は label の検証で拒否される
    for label in ["spam", ""] {
      XCTAssertEqual(
        try messagingErrorReason(mediaChannel: mediaChannel, label: label),
        "label should start with #",
        "label の検証で拒否されること: label => \(label)")
    }

    // `#` で始まる未登録の label (`#` のみを含む) は DataChannel が見つからない
    for label in ["#egg", "#"] {
      XCTAssertEqual(
        try messagingErrorReason(mediaChannel: mediaChannel, label: label),
        "no DataChannel found: label => \(label)",
        "未登録の label が拒否されること: label => \(label)")
    }

    // 登録済みの label は readyState の検証まで進む (label の検証が先に行われることの対照)
    XCTAssertEqual(
      try messagingErrorReason(mediaChannel: mediaChannel, label: "#spam"),
      "readyState of the DataChannel is not open: label => #spam, readyState => connecting",
      "登録済みの label は label の検証を通過すること")

    // switched が false の場合は label の検証より先に拒否される
    peerChannel.switchedToDataChannel = false
    XCTAssertEqual(
      try messagingErrorReason(mediaChannel: mediaChannel, label: "spam"),
      "DataChannel is not open yet",
      "switched の検証が label の検証より先であること")
  }

  // sendMessage(label:data:) が返す `SoraError.messagingError` の reason を取り出す
  private func messagingErrorReason(
    mediaChannel: MediaChannel, label: String = "#spam"
  ) throws -> String {
    guard let error = mediaChannel.sendMessage(label: label, data: Data([0x01])) else {
      XCTFail("sendMessage が messagingError を返すこと")
      throw UnexpectedState()
    }
    guard case SoraError.messagingError(let reason) = error else {
      XCTFail("messagingError が返ること: \(error)")
      throw UnexpectedState()
    }
    return reason
  }
}
