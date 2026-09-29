import Foundation
import WebRTC
import XCTest

@testable import Sora

/// DataChannel で受信したメッセージをテストスレッドへ渡す観測用の delegate です。
///
/// `@unchecked Sendable` としているのは、可変状態が `received` だけで、その読み書きを
/// すべて `lock` で排他しているためです (WebRTC の callback は別スレッドから届きます)。
/// 受信を待つ expectation は不変で、fulfill はどのスレッドから呼んでも安全です。
private final class DataChannelMessageRecorder: NSObject, RTCDataChannelDelegate,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var received: [Data] = []
  private let expectation: XCTestExpectation

  init(expectation: XCTestExpectation) {
    self.expectation = expectation
  }

  func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
    // 状態遷移は観測しない
  }

  func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
    lock.lock()
    received.append(buffer.data)
    lock.unlock()
    expectation.fulfill()
  }

  /// 受信したメッセージの写しを返す
  var messages: [Data] {
    lock.lock()
    defer { lock.unlock() }
    return received
  }
}

/// WebRTC の callback とテストスレッド間の値をロックで受け渡す箱です。
///
/// `@unchecked Sendable` としているのは、可変状態が `value` だけで、その読み書きを
/// すべて `lock` で排他しているためです (WebRTC の callback は別スレッドから届きます)。
private final class LockedValue<Value>: @unchecked Sendable {
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

/// 統計要求の受信経路が実 `RTCDataChannel` の `send` を呼ぶことを確認する。
///
/// Sora サーバーを使わず、2 つの実 `RTCPeerConnection` をローカルで接続する。ICE は
/// ローカル候補だけを交換し、STUN / TURN サーバーを使わない。DataChannel は両側で同じ
/// channelId の externally negotiated な channel として作るため、`didOpen` の通知を
/// 待たずに両側の channel を参照できる。
final class DataChannelStatsSendTests: XCTestCase {
  /// 実 PeerChannel を保持する
  ///
  /// `dataChannels` に登録した `DataChannel` が delegate 経由で参照するため、テストの間は
  /// 解放しないよう instance で保持する。
  private var peerChannel: PeerChannel?

  override func tearDown() {
    peerChannel = nil
    super.tearDown()
  }

  /// 統計要求の受信後に、統計 JSON が実 DataChannel で送信されることを確認する
  ///
  /// `BasicDataChannelDelegate` は `statistics` の完了 block から `DataChannel.send(_:)` を
  /// 呼ぶ。この送信が実 channel へ届くことを、対向の PeerConnection で観測する。
  func testStatsCompletionSendsOverRealDataChannel() throws {
    // RTCPeerConnectionFactory は PeerConnection より長生きさせる必要がある
    let factory = try NativePeerChannelFactory(bypassVoiceProcessing: false)
    let sender = try makeTestPeerConnection(factory: factory)
    let receiver = try makeTestPeerConnection(factory: factory)

    // 両側で同じ channelId の externally negotiated な DataChannel を作る
    let dataChannelConfiguration = RTCDataChannelConfiguration()
    dataChannelConfiguration.isNegotiated = true
    dataChannelConfiguration.channelId = 1
    let senderDataChannel = try XCTUnwrap(
      sender.dataChannel(forLabel: "stats", configuration: dataChannelConfiguration),
      "送信側の DataChannel を生成できること")
    let receiverDataChannel = try XCTUnwrap(
      receiver.dataChannel(forLabel: "stats", configuration: dataChannelConfiguration),
      "受信側の DataChannel を生成できること")

    let received = expectation(description: "統計 JSON を実 DataChannel で受信できること")
    let recorder = DataChannelMessageRecorder(expectation: received)
    senderDataChannel.delegate = recorder

    // 統計要求を受信する側の DataChannel を実 PeerChannel へ登録する
    let peerChannel = try makePeerChannel(factory: factory)
    self.peerChannel = peerChannel
    peerChannel.nativeChannel = receiver
    peerChannel.dataChannels["stats"] = DataChannel(
      dataChannel: receiverDataChannel,
      compress: false,
      mediaChannel: nil,
      peerChannel: peerChannel,
      generation: peerChannel.dataChannelGeneration)

    defer {
      // 解放時の状態通知から統計送信経路の delegate が呼ばれないようにしてから閉じる
      senderDataChannel.delegate = nil
      receiverDataChannel.delegate = nil
      peerChannel.nativeChannel = nil
      sender.close()
      receiver.close()
    }

    try connect(sender: sender, receiver: receiver)

    let opened = expectation(
      for: NSPredicate { _, _ in
        senderDataChannel.readyState == .open && receiverDataChannel.readyState == .open
      }, evaluatedWith: nil)
    wait(for: [opened], timeout: 20)

    // 統計要求を実 DataChannel で送ると、受信側の delegate が統計 JSON を送り返す
    XCTAssertTrue(
      senderDataChannel.sendData(RTCDataBuffer(data: Data("request".utf8), isBinary: true)),
      "統計要求を実 DataChannel で送信できること")

    wait(for: [received], timeout: 20)
    let messages = recorder.messages
    XCTAssertEqual(messages.count, 1, "統計 JSON の送信が 1 回だけ届くこと")
    let data = try XCTUnwrap(messages.first, "統計 JSON を受信できること")
    let json = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: data) as? [String: Any],
      "受信したメッセージが JSON オブジェクトであること")
    XCTAssertEqual(json["type"] as? String, "stats", "統計 JSON の type が stats であること")
    XCTAssertNotNil(json["reports"], "統計 JSON が reports を持つこと")
  }

  /// テスト用の `PeerChannel` を構築する
  ///
  /// 接続は行わないため、`dataChannelGeneration` は初期値のままである。
  private func makePeerChannel(factory: NativePeerChannelFactory) throws -> PeerChannel {
    let configuration = makeTestConfiguration()
    let snapshot = try ConnectionConfigurationSnapshot(configuration: configuration)
    let signalingChannel = SignalingChannel(
      snapshot: snapshot,
      webSocketChannelHandlers: configuration.webSocketChannelHandlers)
    return PeerChannel(
      snapshot: snapshot,
      signalingChannel: signalingChannel,
      nativePeerChannelFactory: factory,
      mediaChannel: nil)
  }

  /// 2 つの PeerConnection をローカルの候補だけで接続する
  ///
  /// candidate を SDP に含めてから相手へ渡し、trickle ICE の通知実装を不要にする。
  private func connect(sender: RTCPeerConnection, receiver: RTCPeerConnection) throws {
    try setDescription(try description(peer: sender, answer: false), peer: sender, local: true)
    waitForCandidates(peer: sender)
    try setDescription(try XCTUnwrap(sender.localDescription), peer: receiver, local: false)
    try setDescription(try description(peer: receiver, answer: true), peer: receiver, local: true)
    waitForCandidates(peer: receiver)
    try setDescription(try XCTUnwrap(receiver.localDescription), peer: sender, local: false)
  }

  private func description(peer: RTCPeerConnection, answer: Bool) throws -> RTCSessionDescription {
    let completed = expectation(description: "SDP を生成できること")
    let result = LockedValue<RTCSessionDescription>()
    let callback: @Sendable (RTCSessionDescription?, Error?) -> Void = { description, error in
      XCTAssertNil(error)
      if let description { result.set(description) }
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
    let failure = LockedValue<Error>()
    let callback: @Sendable (Error?) -> Void = { error in
      if let error { failure.set(error) }
      completed.fulfill()
    }
    if local {
      peer.setLocalDescription(description, completionHandler: callback)
    } else {
      peer.setRemoteDescription(description, completionHandler: callback)
    }
    wait(for: [completed], timeout: 10)
    if let error = failure.get() { throw error }
  }

  private func waitForCandidates(peer: RTCPeerConnection) {
    let gathered = expectation(
      for: NSPredicate { _, _ in peer.iceGatheringState == .complete }, evaluatedWith: nil)
    wait(for: [gathered], timeout: 20)
  }
}
