import WebRTC
import XCTest

@testable import Sora

/// WebRTC の imported enum の文字列化 (`WebRTCEnumDescription`) のテストです。
///
/// imported type へ protocol conformance を追加しない理由: 別 module の型を別 module の
/// protocol に準拠させると retroactive conformance の warning (SE-0364) が出て、将来 WebRTC 側が
/// 同じ準拠を追加した場合に衝突します。そのため文字列化は SDK 内部の formatter で行い、
/// 既知 case の文字列表現と、未知 raw value でプロセスが終了しないこと
/// (`init?(rawValue:)` が未知の raw value でも nil を返さないため実行時に作れる) を
/// このテストで固定します。
final class RTCDescriptionTests: XCTestCase {
  /// 復元用に保存する `Logger.shared` の設定です。
  ///
  /// `Logger.shared` はプロセス全体の共有状態のため、書き換えるテストは
  /// `setUp` / `tearDown` で復元します。instance 自体は差し替えないため保存しません。
  private var originalLevel: LogLevel = .info
  private var originalGroups: [Logger.Group] = [.channels, .user]
  private var originalOnOutputHandler: ((Log) -> Void)?

  /// ログの確認に使う factory です。
  ///
  /// `RTCPeerConnectionFactory` は PeerConnection と track より長生きさせる必要があります
  /// (先に解放すると、transceiver の破棄が破棄済みの task queue を参照してクラッシュします)。
  /// テストメソッドのローカル変数より後に解放されるよう instance で保持し、`tearDown` で解放します。
  private var peerConnectionFactory: NativePeerChannelFactory?

  override func setUp() {
    super.setUp()
    originalLevel = Logger.shared.level
    originalGroups = Logger.shared.groups
    originalOnOutputHandler = Logger.shared.onOutputHandler
  }

  override func tearDown() {
    Logger.shared.level = originalLevel
    Logger.shared.groups = originalGroups
    Logger.shared.onOutputHandler = originalOnOutputHandler
    peerConnectionFactory = nil
    super.tearDown()
  }

  // MARK: - 既知 case の文字列表現

  // RTCSignalingState の既知 case が既存の description と同じ文字列になることを確認する
  func testSignalingStateDescription() {
    let cases: [(RTCSignalingState, String)] = [
      (.stable, "stable"),
      (.haveLocalOffer, "haveLocalOffer"),
      (.haveLocalPrAnswer, "haveLocalPrAnswer"),
      (.haveRemoteOffer, "haveRemoteOffer"),
      (.haveRemotePrAnswer, "haveRemotePrAnswer"),
      (.closed, "closed"),
    ]
    for (value, expected) in cases {
      XCTAssertEqual(
        WebRTCEnumDescription.signalingState(value), expected,
        "RTCSignalingState.rawValue \(value.rawValue) の文字列が \(expected) と一致しません")
    }
  }

  // RTCIceConnectionState の既知 case (count を含む) が同じ文字列になることを確認する
  func testIceConnectionStateDescription() {
    let cases: [(RTCIceConnectionState, String)] = [
      (.new, "new"),
      (.checking, "checking"),
      (.connected, "connected"),
      (.completed, "completed"),
      (.failed, "failed"),
      (.disconnected, "disconnected"),
      (.closed, "closed"),
      (.count, "count"),
    ]
    for (value, expected) in cases {
      XCTAssertEqual(
        WebRTCEnumDescription.iceConnectionState(value), expected,
        "RTCIceConnectionState.rawValue \(value.rawValue) の文字列が \(expected) と一致しません")
    }
  }

  // RTCIceGatheringState の既知 case が同じ文字列になることを確認する
  func testIceGatheringStateDescription() {
    let cases: [(RTCIceGatheringState, String)] = [
      (.new, "new"),
      (.gathering, "gathering"),
      (.complete, "complete"),
    ]
    for (value, expected) in cases {
      XCTAssertEqual(
        WebRTCEnumDescription.iceGatheringState(value), expected,
        "RTCIceGatheringState.rawValue \(value.rawValue) の文字列が \(expected) と一致しません")
    }
  }

  // RTCDataChannelState の既知 case が同じ文字列になることを確認する
  func testDataChannelStateDescription() {
    let cases: [(RTCDataChannelState, String)] = [
      (.connecting, "connecting"),
      (.open, "open"),
      (.closing, "closing"),
      (.closed, "closed"),
    ]
    for (value, expected) in cases {
      XCTAssertEqual(
        WebRTCEnumDescription.dataChannelState(value), expected,
        "RTCDataChannelState.rawValue \(value.rawValue) の文字列が \(expected) と一致しません")
    }
  }

  // RTCPriority の既知 case が同じ文字列になることを確認する
  func testPriorityDescription() {
    let cases: [(RTCPriority, String)] = [
      (.veryLow, "very-low"),
      (.low, "low"),
      (.medium, "medium"),
      (.high, "high"),
    ]
    for (value, expected) in cases {
      XCTAssertEqual(
        WebRTCEnumDescription.priority(value), expected,
        "RTCPriority.rawValue \(value.rawValue) の文字列が \(expected) と一致しません")
    }
  }

  // RTCDegradationPreference の raw value が既存の description と同じ文字列になることを確認する
  //
  // 値 0 の正式名は RTCDegradationPreferenceMaintainFramerateAndResolution で、
  // RTCDegradationPreferenceDisabled は削除予定の別名 (RTCRtpParameters.h の
  // TODO(webrtc:450044904)) のため、削除予定でないシンボルで検証する。
  func testDegradationPreferenceDescription() {
    let cases: [(RTCDegradationPreference, String)] = [
      (.maintainFramerateAndResolution, "disabled"),
      (.maintainFramerate, "maintain-framerate"),
      (.maintainResolution, "maintain-resolution"),
      (.balanced, "balanced"),
    ]
    for (value, expected) in cases {
      XCTAssertEqual(
        WebRTCEnumDescription.degradationPreference(rawValue: value.rawValue), expected,
        "RTCDegradationPreference.rawValue \(value.rawValue) の文字列が \(expected) と一致しません")
    }

    // degradationPreference が未設定の場合は "-" になる
    XCTAssertEqual(
      WebRTCEnumDescription.degradationPreference(rawValue: nil), "-",
      "未設定の場合は - になること")
  }

  // MARK: - 未知 raw value

  // 未知の raw value でもプロセスが終了せず、診断できる文字列を返すことを確認する
  //
  // imported な NS_ENUM の init?(rawValue:) は未知の raw value でも nil を返さないため、
  // 実行時に未知値を作って確認できる。型ごとに異なる値を使い、raw value の取り違えを検出できる
  // ようにする。
  func testUnknownRawValueDescriptions() throws {
    XCTAssertEqual(
      WebRTCEnumDescription.signalingState(try XCTUnwrap(RTCSignalingState(rawValue: 99))),
      "unknown(99)", "未知の raw value の文字列が unknown(99) と一致しません")
    XCTAssertEqual(
      WebRTCEnumDescription.iceConnectionState(try XCTUnwrap(RTCIceConnectionState(rawValue: 98))),
      "unknown(98)", "未知の raw value の文字列が unknown(98) と一致しません")
    XCTAssertEqual(
      WebRTCEnumDescription.iceGatheringState(try XCTUnwrap(RTCIceGatheringState(rawValue: 97))),
      "unknown(97)", "未知の raw value の文字列が unknown(97) と一致しません")
    XCTAssertEqual(
      WebRTCEnumDescription.dataChannelState(try XCTUnwrap(RTCDataChannelState(rawValue: 96))),
      "unknown(96)", "未知の raw value の文字列が unknown(96) と一致しません")
    XCTAssertEqual(
      WebRTCEnumDescription.priority(try XCTUnwrap(RTCPriority(rawValue: 95))),
      "unknown(95)", "未知の raw value の文字列が unknown(95) と一致しません")
    // RTCDegradationPreference は値 0 の別名がある型のため Int の経路で負値も確認する
    XCTAssertEqual(
      WebRTCEnumDescription.degradationPreference(rawValue: -1), "unknown(-1)",
      "未知の raw value (負値) の文字列が unknown(-1) と一致しません")
  }

  // MARK: - RTCRtpParameters.description

  // RTCRtpParameters.description が formatter の文字列を使い、Optional の補間を含まないことを確認する
  //
  // 変更前は String(describing:) に Optional を渡していたため `Optional(disabled)` のような文字列に
  // なっていた。以下の完全一致が `Optional(` と `__C.` を含まないことの検証も兼ねる。
  func testRTCRtpParametersDescription() {
    let parameters = RTCRtpParameters()
    parameters.transactionId = "tx"

    // degradationPreference が未設定の場合は "-" になる
    XCTAssertEqual(parameters.description, "tx -", "未設定の場合は - になること")

    parameters.degradationPreference = NSNumber(value: -1)
    XCTAssertEqual(
      parameters.description, "tx unknown(-1)", "未知の raw value (負値) の文字列が unknown(-1) になること")

    parameters.degradationPreference = NSNumber(
      value: RTCDegradationPreference.maintainFramerateAndResolution.rawValue)
    XCTAssertEqual(parameters.description, "tx disabled", "値 0 の文字列が disabled になること")

    parameters.degradationPreference = NSNumber(value: RTCDegradationPreference.balanced.rawValue)
    XCTAssertEqual(parameters.description, "tx balanced", "値 3 の文字列が balanced になること")

    parameters.degradationPreference = NSNumber(value: 99)
    XCTAssertEqual(
      parameters.description, "tx unknown(99)", "未知の raw value の文字列が unknown(99) になること")
  }

  // MARK: - ログの文字列

  // 1 から 5 の文字列化が formatter を通っていることをログで確認する
  //
  // 実 RTCPeerConnection と PeerChannel を使い、delegate メソッドを直接呼んで決定的に
  // 発火させます (Sora サーバーには接続しません)。出力箇所ごとにテストを分け、
  // どのログが壊れたかをテスト結果から判別できるようにします。

  // signaling state (PeerChannel.peerConnection(_:didChange:)) のログを確認する
  func testSignalingStateLogUsesFormatter() throws {
    let collector = makeLogCollector()
    let fixture = try makePeerConnectionFixture()

    // 完全一致で比較し、値の取り違えと余分な文字列の混入を検出できるようにする
    collector.clear()
    fixture.peerChannel.peerConnection(fixture.peerConnection, didChange: RTCSignalingState.stable)
    XCTAssertEqual(
      collector.snapshot(), ["signaling state: stable"],
      "signaling state のログが formatter の文字列になること")

    // 未知の raw value でも delegate の引数がそのまま formatter へ渡ることを確認する
    // (引数を固定値で埋める退行を検出するため)
    collector.clear()
    fixture.peerChannel.peerConnection(
      fixture.peerConnection, didChange: try XCTUnwrap(RTCSignalingState(rawValue: 99)))
    XCTAssertEqual(
      collector.snapshot(), ["signaling state: unknown(99)"],
      "未知の raw value のログが unknown(<rawValue>) になること")
  }

  // ICE connection state (PeerChannel.peerConnection(_:didChange:)) のログを確認する
  func testIceConnectionStateLogUsesFormatter() throws {
    let collector = makeLogCollector()
    let fixture = try makePeerConnectionFixture()

    collector.clear()
    fixture.peerChannel.peerConnection(
      fixture.peerConnection, didChange: RTCIceConnectionState.connected)
    XCTAssertEqual(
      collector.snapshot(), ["ICE connection state: connected"],
      "ICE connection state のログが formatter の文字列になること")

    collector.clear()
    fixture.peerChannel.peerConnection(
      fixture.peerConnection, didChange: try XCTUnwrap(RTCIceConnectionState(rawValue: 98)))
    XCTAssertEqual(
      collector.snapshot(), ["ICE connection state: unknown(98)"],
      "未知の raw value のログが unknown(<rawValue>) になること")
  }

  // ICE gathering state (PeerChannel.peerConnection(_:didChange:)) のログを確認する
  func testIceGatheringStateLogUsesFormatter() throws {
    let collector = makeLogCollector()
    let fixture = try makePeerConnectionFixture()

    collector.clear()
    fixture.peerChannel.peerConnection(
      fixture.peerConnection, didChange: RTCIceGatheringState.complete)
    XCTAssertEqual(
      collector.snapshot(), ["ICE gathering state: complete"],
      "ICE gathering state のログが formatter の文字列になること")

    collector.clear()
    fixture.peerChannel.peerConnection(
      fixture.peerConnection, didChange: try XCTUnwrap(RTCIceGatheringState(rawValue: 97)))
    XCTAssertEqual(
      collector.snapshot(), ["ICE gathering state: unknown(97)"],
      "未知の raw value のログが unknown(<rawValue>) になること")
  }

  // networkPriority (RTCRtpSender.updateOfferEncodings(_:)) のログを確認する
  func testNetworkPriorityLogUsesFormatter() throws {
    let collector = makeLogCollector()
    let fixture = try makePeerConnectionFixture()

    // updateOfferEncodings(_:) は sender の parameters.encodings と rid が一致した encoding の
    // networkPriority だけをログへ出すため、sender を 1 つ追加して rid を nil 同士で一致させる
    let track = makeAudioTrack(factory: fixture.factory)
    let sender = try XCTUnwrap(
      fixture.peerConnection.add(track, streamIds: ["stream"]),
      "RTCRtpSender を取得できること")

    // 前提が崩れると「formatter を通っていない」ように見えるため、前提も確認する。
    // 既定値 (low) と異なる値を渡すことで、代入前の古い値をログへ出す退行も検出できる
    XCTAssertEqual(sender.parameters.encodings.count, 1, "add(track) 直後の encoding が 1 つであること")
    XCTAssertNil(sender.parameters.encodings.first?.rid, "add(track) 直後の rid が nil であること")
    XCTAssertEqual(
      sender.parameters.encodings.first?.networkPriority, .low,
      "add(track) 直後の networkPriority が既定値 (low) であること")

    collector.clear()
    sender.updateOfferEncodings([
      SignalingOffer.Encoding(
        active: true,
        rid: nil,
        maxBitrate: nil,
        maxFramerate: nil,
        scaleResolutionDownBy: nil,
        scaleResolutionDownTo: nil,
        scalabilityMode: nil,
        networkPriority: .veryLow)
    ])
    // updateOfferEncodings(_:) は networkPriority 以外のログも出すため、対象のログだけを取り出す
    XCTAssertEqual(
      collector.snapshot().filter { $0.hasPrefix("networkPriority:") },
      ["networkPriority: very-low"],
      "networkPriority のログが formatter の文字列になること")
  }

  // DataChannel の ready state (BasicDataChannelDelegate) のログを確認する
  func testDataChannelStateLogUsesFormatter() throws {
    let collector = makeLogCollector()
    let fixture = try makePeerConnectionFixture()

    // 交渉前の readyState は .connecting になる。ログは generation の照合より前に出るため、
    // generation が一致しなくても捕捉できる
    let dataChannel = try makeTestDataChannel(
      peerConnection: fixture.peerConnection, label: "#spam")
    XCTAssertEqual(dataChannel.readyState, .connecting, "交渉前の readyState が connecting であること")
    collector.clear()
    BasicDataChannelDelegate(
      compress: false,
      mediaChannel: nil,
      peerChannel: fixture.peerChannel,
      generation: fixture.peerChannel.dataChannelGeneration
    ).dataChannelDidChangeState(dataChannel)
    XCTAssertEqual(
      collector.snapshot(),
      ["dataChannelDidChangeState(_:): label => #spam, state => connecting"],
      "DataChannel の ready state のログが formatter の文字列になること")

    // close() 後は .closed になる。実 DataChannel の状態をそのままログへ出すことを確認するため
    // (値が固定文字列でないことの確認)、connecting とは異なる状態でも完全一致で比較する。
    // この delegate は generation を一致させないので、ログの後で PeerChannel.disconnect は呼ばれない
    dataChannel.close()
    XCTAssertEqual(dataChannel.readyState, .closed, "close() 後の readyState が closed であること")
    collector.clear()
    BasicDataChannelDelegate(
      compress: false,
      mediaChannel: nil,
      peerChannel: fixture.peerChannel,
      generation: fixture.peerChannel.dataChannelGeneration + 1
    ).dataChannelDidChangeState(dataChannel)
    XCTAssertEqual(
      collector.snapshot(),
      ["dataChannelDidChangeState(_:): label => #spam, state => closed"],
      "DataChannel の ready state のログが formatter の文字列になること")
  }

  // MARK: - テスト用のヘルパー

  /// ログの確認に使う実オブジェクトの組です。
  ///
  /// `RTCPeerConnectionFactory` は PeerConnection より長生きさせる必要があるため、factory も
  /// この組で持ちます。
  private struct PeerConnectionFixture {
    let factory: NativePeerChannelFactory
    let peerChannel: PeerChannel
    let peerConnection: RTCPeerConnection
  }

  // ログを捕捉する collector を用意する (`Logger.shared` の設定は `tearDown` で復元する)
  private func makeLogCollector() -> StringCollector {
    let collector = StringCollector()
    Logger.shared.level = .debug
    Logger.shared.groups = [.channels]
    Logger.shared.onOutputHandler = { log in
      collector.append(log.message)
    }
    return collector
  }

  // ログの確認に使う factory / PeerChannel / RTCPeerConnection を用意する
  //
  // factory は instance で保持して、テストメソッドのローカル変数より後に解放する。
  private func makePeerConnectionFixture() throws -> PeerConnectionFixture {
    let factory = try NativePeerChannelFactory(bypassVoiceProcessing: false)
    peerConnectionFactory = factory
    return PeerConnectionFixture(
      factory: factory,
      peerChannel: try makePeerChannel(factory: factory),
      peerConnection: try makeTestPeerConnection(factory: factory))
  }

  // PeerChannel を生成する
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

  // networkPriority のログを確認するための送信側の track を生成する
  private func makeAudioTrack(factory: NativePeerChannelFactory) -> RTCAudioTrack {
    let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    return factory.createNativeAudioTrack(trackId: "audio", constraints: constraints)
  }

}
