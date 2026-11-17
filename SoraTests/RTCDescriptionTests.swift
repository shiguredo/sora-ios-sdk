import WebRTC
import XCTest

@testable import Sora

/// WebRTC の imported enum の文字列化 (`WebRTCEnumDescription`) と、
/// `RTCPeerConnectionDelegate` / `RTCDataChannelDelegate` のログ出力のテストです。
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

  // RTCPeerConnectionState の既知 case が case 名になることを確認する
  func testPeerConnectionStateDescription() {
    let cases: [(RTCPeerConnectionState, String)] = [
      (.new, "new"),
      (.connecting, "connecting"),
      (.connected, "connected"),
      (.disconnected, "disconnected"),
      (.failed, "failed"),
      (.closed, "closed"),
    ]
    for (value, expected) in cases {
      XCTAssertEqual(
        WebRTCEnumDescription.peerConnectionState(value), expected,
        "RTCPeerConnectionState.rawValue \(value.rawValue) の文字列が \(expected) と一致しません")
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
    XCTAssertEqual(
      WebRTCEnumDescription.peerConnectionState(
        try XCTUnwrap(RTCPeerConnectionState(rawValue: 94))),
      "unknown(94)", "未知の raw value の文字列が unknown(94) と一致しません")
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

  // collector が他のコンポーネントのログを collect しないことを確認する
  //
  // `PeerChannel` 以外のログ (他のテストが残した接続試行の非同期ログなど) を collect すると、
  // ログの一覧を完全一致で比較するテストが実行順に依存して失敗する。
  func testLogCollectorIgnoresLogsFromOtherComponents() {
    let collector = makeLogCollector()

    Logger.debug(type: .webSocketChannel, message: "other component log")
    XCTAssertEqual(
      collector.snapshot(), [],
      "収集対象外のログを collect しないこと")

    Logger.debug(type: .peerChannel, message: "peer channel log")
    Logger.debug(type: .dataChannel, message: "data channel log")
    XCTAssertEqual(
      collector.snapshot(), ["peer channel log", "data channel log"],
      "収集対象のログを collect すること")
  }

  // 文字列化が formatter を通っていることと、delegate のログを確認する
  //
  // 実 RTCPeerConnection と PeerChannel を使い、delegate メソッドを直接呼ぶか、
  // 実際の ICE 収集を失敗させてログを捕捉します (Sora サーバーには接続しません)。
  // 出力箇所ごとにテストを分け、どのログが壊れたかをテスト結果から判別できるようにします。

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

  // ICE candidate の収集失敗 (PeerChannel.peerConnection(_:didFailToGatherIceCandidate:)) のログを確認する
  func testIceCandidateErrorLog() throws {
    let capture = LoggerCapture()
    let fixture = try makePeerConnectionFixture()

    // RTCPeerConnectionDelegate の実装は先頭の isCurrentPeerConnection(_:) が
    // nativeChannel との同一性を要求するため、テスト対象の RTCPeerConnection を設定する。
    fixture.peerChannel.nativeChannel = fixture.peerConnection
    defer { fixture.peerChannel.nativeChannel = nil }

    // optional requirement のセレクタ露出も検証するため、具象型ではなく
    // RTCPeerConnectionDelegate の existential 経由で呼ぶ。
    let delegate: RTCPeerConnectionDelegate = fixture.peerChannel

    // RTCIceCandidateErrorEvent() の文字列プロパティは nil のまま生成され、
    // Swift の String へブリッジすると空文字列になる。数値プロパティは 0 になる。
    // public API では任意の値のイベントを生成できないため、このテストでは
    // メッセージ形式、ログのレベル・種別、ガードを固定する。実値の対応は
    // testIceCandidateErrorLogWithRealFailedGathering で確認する。
    delegate.peerConnection?(
      fixture.peerConnection, didFailToGatherIceCandidate: RTCIceCandidateErrorEvent())

    let logs = capture.logs.filter { $0.message.hasPrefix("failed to gather ICE candidate:") }
    XCTAssertEqual(
      logs.map(\.message),
      ["failed to gather ICE candidate: url= errorCode=0 errorText= address= port=0"],
      "ICE candidate の収集失敗ログが 5 フィールドを含む形式で出力されること")
    let log = try XCTUnwrap(logs.first, "ICE candidate の収集失敗ログの Log を取得できること")
    XCTAssertEqual(log.level.description, "DEBUG", "ログレベルが DEBUG であること")
    XCTAssertEqual(log.type.description, "PeerChannel", "ログ種別が PeerChannel であること")

    // nativeChannel と一致しない RTCPeerConnection からの通知は無視される。
    // 別の PC を渡し、両方 non-nil の identity mismatch を確認する。
    let failedCount = logs.count
    let other = try makeTestPeerConnection(factory: fixture.factory)
    delegate.peerConnection?(other, didFailToGatherIceCandidate: RTCIceCandidateErrorEvent())
    XCTAssertEqual(
      capture.logs.filter { $0.message.hasPrefix("failed to gather ICE candidate:") }.count,
      failedCount,
      "nativeChannel と一致しない RTCPeerConnection からの通知はログを出力しないこと")

    // nativeChannel が無い場合もログを出力しない。
    fixture.peerChannel.nativeChannel = nil
    delegate.peerConnection?(
      fixture.peerConnection, didFailToGatherIceCandidate: RTCIceCandidateErrorEvent())
    XCTAssertEqual(
      capture.logs.filter { $0.message.hasPrefix("failed to gather ICE candidate:") }.count,
      failedCount,
      "nativeChannel が無いときの通知はログを出力しないこと")
  }

  // 既定のログレベル (info) では ICE candidate の収集失敗ログが出力されないことを確認する
  func testIceCandidateErrorLogIsSuppressedAtInfoLevel() throws {
    let capture = LoggerCapture(level: .info)
    let fixture = try makePeerConnectionFixture()
    fixture.peerChannel.nativeChannel = fixture.peerConnection
    defer { fixture.peerChannel.nativeChannel = nil }

    let delegate: RTCPeerConnectionDelegate = fixture.peerChannel
    delegate.peerConnection?(
      fixture.peerConnection, didFailToGatherIceCandidate: RTCIceCandidateErrorEvent())

    XCTAssertTrue(
      capture.logs.filter { $0.message.hasPrefix("failed to gather ICE candidate:") }.isEmpty,
      "既定のログレベル (info) では ICE candidate の収集失敗ログが出力されないこと")
  }

  // 実 PC で ICE 収集を失敗させ、5 フィールドの実値対応を確認する
  func testIceCandidateErrorLogWithRealFailedGathering() throws {
    let fixture = try makePeerConnectionFixture()
    let logged = expectation(description: "ICE candidate の収集失敗ログが出力されること")
    logged.assertForOverFulfill = false
    let capture = LoggerCapture(onMessage: { message in
      if message.hasPrefix("failed to gather ICE candidate:") {
        logged.fulfill()
      }
    })

    let peerConnection = try makeIceFailurePeerConnection(
      factory: fixture.factory, delegate: fixture.peerChannel)
    fixture.peerChannel.nativeChannel = peerConnection
    defer { fixture.peerChannel.nativeChannel = nil }

    // data channel を作って m-line を作り、offer と setLocalDescription で ICE 収集を開始する。
    _ = try makeTestDataChannel(peerConnection: peerConnection, label: "#ice-error")
    let offer = try makeOffer(peerConnection)
    try setLocalDescription(offer, peerConnection: peerConnection)

    // 最初の失敗ログだけでなく gathering の完了まで待つ。gathering 完了まで
    // ICE 関連の delegate ログが続くため、完了前に LoggerCapture を解放すると
    // 後続テストへログが漏れる。
    let gathered = expectation(
      for: NSPredicate { _, _ in peerConnection.iceGatheringState == .complete },
      evaluatedWith: nil)
    wait(for: [logged, gathered], timeout: 20)

    let logs = capture.logs.filter { $0.message.hasPrefix("failed to gather ICE candidate:") }
    XCTAssertFalse(logs.isEmpty, "ICE candidate の収集失敗ログが 1 件以上出力されること")
    let log = try XCTUnwrap(
      logs.first, "ICE candidate の収集失敗ログの Log を取得できること")

    // url と errorCode は前方一致、errorText は空でないこと、address / port は
    // 末尾一致で比較し、フィールドの取り違えを検出する。このテスト環境では
    // address が空、port が 0 になる。
    let message = log.message
    XCTAssertTrue(
      message.hasPrefix(
        "failed to gather ICE candidate: url=turn:127.0.0.1:65535?transport=tcp errorCode=701 errorText="
      ),
      "url と errorCode が実値で出力されること: \(message)")
    XCTAssertFalse(
      message.contains("errorText= address="),
      "errorText が空でないこと: \(message)")
    XCTAssertTrue(
      message.hasSuffix(" address= port=0"),
      "address が空、port が 0 で出力されること: \(message)")
  }

  // peer connection state (PeerChannel.peerConnection(_:didChange:)) のログを確認する
  func testPeerConnectionStateLogUsesFormatter() throws {
    let collector = makeLogCollector()
    let fixture = try makePeerConnectionFixture()

    // RTCPeerConnectionState 版の delegate は先頭の isCurrentPeerConnection(_:) が
    // nativeChannel との同一性を要求する。既存のログテストが呼ぶ state 系の didChange は
    // このガードを持たないため、このテストだけ nativeChannel に実 RTCPeerConnection を代入する。
    fixture.peerChannel.nativeChannel = fixture.peerConnection
    defer { fixture.peerChannel.nativeChannel = nil }

    // .connecting は cancelDisconnectTimer() だけを呼び、タイマー未開始では追加のログを出さない。
    // .connected は finishConnecting() 経由で追加のログと endAsyncOperation() を呼び、
    // 非同期処理を開始していないこの fixture では assertionFailure でテストが停止する。
    collector.clear()
    fixture.peerChannel.peerConnection(
      fixture.peerConnection, didChange: RTCPeerConnectionState.connecting)
    XCTAssertEqual(
      collector.snapshot(), ["peer connection state: connecting"],
      "peer connection state のログが formatter の文字列になること")

    // 未知の raw value でも delegate の引数がそのまま formatter へ渡ることを確認する。
    // formatter 単体のテストとは異なる値を使い、引数を固定値で埋める退行も検出できるようにする。
    collector.clear()
    fixture.peerChannel.peerConnection(
      fixture.peerConnection, didChange: try XCTUnwrap(RTCPeerConnectionState(rawValue: 93)))
    XCTAssertEqual(
      collector.snapshot(), ["peer connection state: unknown(93)"],
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
      // 確認するのは、この fixture が使う PeerChannel と DataChannel のログだけである。
      // 他のテストが残した接続試行の非同期ログ (WebSocket のエラーなど) が
      // 完全一致の比較へ混入しないよう、ログ種別で絞り込む。
      switch log.type {
      case .peerChannel, .dataChannel:
        collector.append(log.message)
      default:
        break
      }
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

  // ICE 収集失敗を発生させるための TURN TCP の設定で RTCPeerConnection を生成する。
  //
  // 127.0.0.1:65535 に listener が無い前提で、TURN TCP の接続確立に失敗させる。
  // TURN TCP は ready にならないまま ICE gathering のタイムアウト (実測約 8 秒) で
  // gathering が完了し、errorCode 701 / 実装固有の errorText / address 空 / port 0 が通知される。
  private func makeIceFailurePeerConnection(
    factory: NativePeerChannelFactory,
    delegate: RTCPeerConnectionDelegate
  ) throws -> RTCPeerConnection {
    let configuration = RTCConfiguration()
    configuration.sdpSemantics = .unifiedPlan
    configuration.iceTransportPolicy = .relay
    configuration.iceServers = [
      RTCIceServer(
        urlStrings: ["turn:127.0.0.1:65535?transport=tcp"],
        username: "test",
        credential: "test")
    ]
    let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    return try XCTUnwrap(
      factory.nativeFactory.peerConnection(
        with: configuration, constraints: constraints, delegate: delegate),
      "ICE 収集失敗用の RTCPeerConnection を生成できること")
  }

  // offer を生成する
  //
  // DataChannelStatsSendTests の description / setDescription と同型の helper である。
  // テストファイルをまたぐ共有化は、既存テストを含む別の整理として行う。
  private func makeOffer(_ peerConnection: RTCPeerConnection) throws -> RTCSessionDescription {
    let completed = expectation(description: "offer を生成できること")
    let result = LockedValue<RTCSessionDescription>()
    let callback: @Sendable (RTCSessionDescription?, Error?) -> Void = { description, error in
      XCTAssertNil(error, "offer の生成がエラーなく完了すること")
      if let description {
        result.set(description)
      }
      completed.fulfill()
    }
    peerConnection.offer(
      for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
      completionHandler: callback)
    wait(for: [completed], timeout: 10)
    return try XCTUnwrap(result.get(), "SDP を取得できること")
  }

  // local description を設定する
  //
  // DataChannelStatsSendTests の setDescription と同型の helper である。
  // テストファイルをまたぐ共有化は、既存テストを含む別の整理として行う。
  private func setLocalDescription(
    _ description: RTCSessionDescription, peerConnection: RTCPeerConnection
  ) throws {
    let completed = expectation(description: "local description を設定できること")
    let failure = LockedValue<Error>()
    let callback: @Sendable (Error?) -> Void = { error in
      if let error {
        failure.set(error)
      }
      completed.fulfill()
    }
    peerConnection.setLocalDescription(description, completionHandler: callback)
    wait(for: [completed], timeout: 10)
    if let error = failure.get() {
      throw error
    }
  }

}

/// WebRTC の callback とテストスレッド間で値をロックして受け渡す箱です。
///
/// `@unchecked Sendable` としているのは、可変状態が `value` だけで、その読み書きを
/// すべて `lock` で排他しているためです (WebRTC の callback は別スレッドから届きます)。
///
/// DataChannelStatsSendTests / PeerChannelMessagingRaceTests に同型の実装がある。
/// テストファイルをまたぐ共有化は、既存テストを含む別の整理として行う。
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
