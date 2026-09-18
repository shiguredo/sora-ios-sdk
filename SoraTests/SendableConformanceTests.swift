import AVFoundation
import XCTest

@testable import Sora

/// 型が `Sendable` に準拠していることをコンパイル時に表明する。
///
/// この関数は「`Sendable` への適合が存在すること」だけを確認する。
/// `@unchecked Sendable` を付与した型でも通るため、checked であることの根拠にはしない。
/// checked であることは、対象型へ `@unchecked Sendable` を付与していないことを
/// 差分で確認して担保する。
///
/// 同じテストターゲットの他のテストファイルからも使うため internal とする。
func requireSendable<T: Sendable>(_: T.Type) {}

/// 値を actor 境界の向こう側へ預け、取り出せることを確認するための actor。
///
/// `Sendable` に準拠していない値は `store` へ渡せないため、準拠の欠落はコンパイルで検出される。
private actor SendableBoundaryProbe<Value: Sendable> {
  private var stored: Value?

  func store(_ value: Value) {
    stored = value
  }

  func load() -> Value? {
    stored
  }
}

/// 値を actor 境界と Task の境界へ渡せることを確認する。
///
/// `Value` が `Sendable` でなければこの関数を呼び出せない。
private func assertCrossesBoundaries<Value: Sendable>(
  _ value: Value,
  message: String
) async {
  let probe = SendableBoundaryProbe<Value>()

  // 値そのものを Task の closure へ渡し、actor を経由して取り出せることを確認する。
  // Task の closure は @Sendable のため、ここで Value が Sendable であることが要求される。
  let task = Task { () -> Value? in
    await probe.store(value)
    return await probe.load()
  }
  let loaded = await task.value

  XCTAssertNotNil(loaded, message)
}

final class SendableConformanceTests: XCTestCase {
  /// 公開型 (`CameraVideoCapturer` は class) が `Sendable` に準拠していることをコンパイル時に表明する。
  ///
  /// 準拠が欠けた型を 1 つでも渡すとこのテストはコンパイルできない。
  func testPublicTypesConformToSendable() {
    // 接続状態
    requireSendable(ConnectionState.self)

    // WebRTC のメディア制約と劣化設定
    requireSendable(MediaConstraints.self)
    requireSendable(DegradationPreference.self)

    // 音声モードと音声出力先
    requireSendable(AudioMode.self)
    requireSendable(AudioOutput.self)

    // associated value に持つ imported type
    requireSendable(AVAudioSession.Category.self)
    requireSendable(AVCaptureDevice.Position.self)

    // ログ
    requireSendable(LogType.self)
    requireSendable(LogLevel.self)
    requireSendable(Log.self)
    requireSendable(Logger.Group.self)

    // 映像表示
    requireSendable(VideoViewConnectionMode.self)

    // WebSocket メッセージ
    requireSendable(WebSocketMessage.self)

    // 接続タスクの状態
    requireSendable(ConnectionTask.State.self)

    // 設定
    requireSendable(Configuration.Spotlight.self)
    requireSendable(ForwardingFilterRuleField.self)
    requireSendable(ForwardingFilterRuleOperator.self)
    requireSendable(ForwardingFilterAction.self)
    requireSendable(ForwardingFilterRule.self)

    // カメラ設定
    requireSendable(CameraSettings.self)

    // カメラの capturer
    requireSendable(CameraVideoCapturer.self)

    // 切断イベント
    requireSendable(SoraCloseEvent.self)

    // シグナリングメッセージ
    requireSendable(SignalingAnswer.self)
    requireSendable(SignalingUpdate.self)
    requireSendable(SignalingReOffer.self)
    requireSendable(SignalingReAnswer.self)
    requireSendable(SignalingSwitched.self)
    requireSendable(SignalingRedirect.self)
    requireSendable(SignalingClose.self)
    requireSendable(SignalingPing.self)
    requireSendable(SignalingPong.self)
    requireSendable(SignalingDisconnect.self)
  }

  /// 対象の型の値が actor 境界と Task の境界を越えて受け渡せることを確認する。
  func testValuesCrossActorAndTaskBoundaries() async {
    await assertCrossesBoundaries(
      ConnectionState.disconnected, message: "ConnectionState が actor 境界を越えられない")

    await assertCrossesBoundaries(
      MediaConstraints(), message: "MediaConstraints が actor 境界を越えられない")
    await assertCrossesBoundaries(
      DegradationPreference.balanced, message: "DegradationPreference が actor 境界を越えられない")

    await assertCrossesBoundaries(AudioMode.videoChat, message: "AudioMode が actor 境界を越えられない")
    await assertCrossesBoundaries(
      AudioMode.default(category: .playAndRecord, output: .speaker),
      message: "AudioMode.default が actor 境界を越えられない")
    await assertCrossesBoundaries(AudioOutput.speaker, message: "AudioOutput が actor 境界を越えられない")

    await assertCrossesBoundaries(LogType.sora, message: "LogType が actor 境界を越えられない")
    await assertCrossesBoundaries(LogLevel.info, message: "LogLevel が actor 境界を越えられない")
    await assertCrossesBoundaries(
      Log(level: .info, type: .sora, message: "sendable check"), message: "Log が actor 境界を越えられない")
    await assertCrossesBoundaries(
      Logger.Group.channels, message: "Logger.Group が actor 境界を越えられない")

    await assertCrossesBoundaries(
      VideoViewConnectionMode.auto, message: "VideoViewConnectionMode が actor 境界を越えられない")

    await assertCrossesBoundaries(
      WebSocketMessage.text("sendable"), message: "WebSocketMessage が actor 境界を越えられない")

    await assertCrossesBoundaries(
      ConnectionTask.State.connecting, message: "ConnectionTask.State が actor 境界を越えられない")

    await assertCrossesBoundaries(
      Configuration.Spotlight.enabled, message: "Configuration.Spotlight が actor 境界を越えられない")
    await assertCrossesBoundaries(
      ForwardingFilterRuleField.kind, message: "ForwardingFilterRuleField が actor 境界を越えられない")
    await assertCrossesBoundaries(
      ForwardingFilterRuleOperator.isIn, message: "ForwardingFilterRuleOperator が actor 境界を越えられない")
    await assertCrossesBoundaries(
      ForwardingFilterAction.block, message: "ForwardingFilterAction が actor 境界を越えられない")
    await assertCrossesBoundaries(
      ForwardingFilterRule(field: .kind, operator: .isIn, values: ["connection_id"]),
      message: "ForwardingFilterRule が actor 境界を越えられない")

    await assertCrossesBoundaries(
      CameraSettings.default, message: "CameraSettings が actor 境界を越えられない")

    await assertCrossesBoundaries(
      SoraCloseEvent.ok(code: 1000, reason: "正常終了"),
      message: "SoraCloseEvent.ok が actor 境界を越えられない")
    await assertCrossesBoundaries(
      SoraCloseEvent.error(SoraError.connectionTimeout),
      message: "SoraCloseEvent.error が actor 境界を越えられない")

    await assertCrossesBoundaries(
      SignalingAnswer(sdp: "answer"), message: "SignalingAnswer が actor 境界を越えられない")
    await assertCrossesBoundaries(
      SignalingUpdate(sdp: "update"), message: "SignalingUpdate が actor 境界を越えられない")
    await assertCrossesBoundaries(
      SignalingReOffer(sdp: "re-offer"), message: "SignalingReOffer が actor 境界を越えられない")
    await assertCrossesBoundaries(
      SignalingReAnswer(sdp: "re-answer"), message: "SignalingReAnswer が actor 境界を越えられない")
    await assertCrossesBoundaries(
      SignalingSwitched(ignoreDisconnectWebSocket: true),
      message: "SignalingSwitched が actor 境界を越えられない")
    await assertCrossesBoundaries(
      SignalingRedirect(location: "wss://example.com"),
      message: "SignalingRedirect が actor 境界を越えられない")
    await assertCrossesBoundaries(
      SignalingClose(code: 1000, reason: "正常終了"), message: "SignalingClose が actor 境界を越えられない")
    await assertCrossesBoundaries(
      SignalingPing(statisticsEnabled: true), message: "SignalingPing が actor 境界を越えられない")
    await assertCrossesBoundaries(
      SignalingPong(), message: "SignalingPong が actor 境界を越えられない")
    await assertCrossesBoundaries(
      SignalingDisconnect(reason: "切断"), message: "SignalingDisconnect が actor 境界を越えられない")
  }

  /// internal なカメラ状態型が `Sendable` に準拠していることをコンパイル時と actor 境界で表明する。
  ///
  /// owner の queue と reducer の間で受け渡す値のため、`Sendable` の欠落はコンパイルで検出する。
  func testCameraStateTypesConformToSendable() async {
    requireSendable(CameraCapturerID.self)
    requireSendable(CameraPhase.self)
    requireSendable(CameraState.self)
    requireSendable(CameraEvent.self)
    requireSendable(CameraEffect.self)

    await assertCrossesBoundaries(
      CameraCapturerID(), message: "CameraCapturerID が actor 境界を越えられない")
    await assertCrossesBoundaries(
      CameraPhase.idle, message: "CameraPhase が actor 境界を越えられない")
    await assertCrossesBoundaries(
      CameraState(), message: "CameraState が actor 境界を越えられない")
    await assertCrossesBoundaries(
      CameraEvent.startRequested(id: CameraCapturerID(), generation: 1),
      message: "CameraEvent が actor 境界を越えられない")
    await assertCrossesBoundaries(
      CameraEffect.publishSnapshot, message: "CameraEffect が actor 境界を越えられない")
  }

  /// internal な snapshot 型が `Sendable` に準拠していることをコンパイル時と actor 境界で表明する。
  ///
  /// 接続開始後の非同期区間へ渡す値のため、`Sendable` の欠落はコンパイルで検出する必要がある。
  func testConnectionConfigurationSnapshotTypesConformToSendable() async throws {
    let configuration = Configuration(
      url: try XCTUnwrap(URL(string: "wss://example.invalid")),
      channelId: "test",
      role: .sendrecv)
    let snapshot = try ConnectionConfigurationSnapshot(configuration: configuration)

    requireSendable(ConnectionConfigurationSnapshot.self)
    requireSendable(ICEServerSnapshot.self)
    requireSendable(WebRTCConfigurationSnapshot.self)
    requireSendable(ForwardingFilterSnapshot.self)
    requireSendable(JSONValue.self)

    await assertCrossesBoundaries(
      snapshot, message: "ConnectionConfigurationSnapshot が actor 境界を越えられない")
    await assertCrossesBoundaries(
      snapshot.webRTCConfiguration,
      message: "WebRTCConfigurationSnapshot が actor 境界を越えられない")
    await assertCrossesBoundaries(
      ICEServerSnapshot(
        urls: ["turns:example.com"], username: "user", credential: "credential",
        isTLSInsecure: false),
      message: "ICEServerSnapshot が actor 境界を越えられない")
    await assertCrossesBoundaries(
      ForwardingFilterSnapshot(
        name: nil, priority: nil, action: nil, rules: [], version: nil, metadata: .null),
      message: "ForwardingFilterSnapshot が actor 境界を越えられない")
    await assertCrossesBoundaries(
      JSONValue.object(["key": .string("value")]),
      message: "JSONValue が actor 境界を越えられない")
  }

  /// `StreamFrameOwner` へ渡す frame payload が `Sendable` に準拠していることをコンパイル時に表明する。
  ///
  /// `requireSendable<T: Sendable>(_: T.Type)` は型引数を取るため実 frame を生成しない。
  /// `@unchecked Sendable` を付与した根拠の妥当性は、型 doc のレビューで確認する。
  func testStreamOwnedFrameConformsToSendable() {
    requireSendable(StreamOwnedFrame.self)
  }
}
