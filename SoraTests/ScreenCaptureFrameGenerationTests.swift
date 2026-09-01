import XCTest

@testable import Sora

/// 画面共有の capture ID 世代管理に関するユニットテスト
///
/// 画面共有を停止して直ちに再開始したときに、停止前に送信キューへ投入された旧フレームが
/// 古い sender stream を使わないことを、capture ID の世代判定 (isActiveCaptureID) で
/// 検証する。モックやスタブは使用しない。
final class ScreenCaptureFrameGenerationTests: XCTestCase {
  // テストで共通利用するシグナリング URL を返す
  private func makeTestURL() -> URL {
    guard let url = URL(string: "wss://example.com") else {
      fatalError("テスト URL の生成に失敗しました")
    }
    return url
  }

  // テスト用の Configuration を構築する
  private func makeConfiguration() -> Configuration {
    let url = makeTestURL()
    return Configuration(
      urlCandidates: [url],
      channelId: "test",
      role: .sendonly)
  }

  // ScreenCaptureController と MediaChannel を構築する
  private func makeScreenCaptureController() -> (
    controller: ScreenCaptureController, mediaChannel: MediaChannel
  ) {
    let mediaChannel = MediaChannel(manager: Sora.shared, configuration: makeConfiguration())
    let controller = ScreenCaptureController(mediaChannel: mediaChannel)
    return (controller, mediaChannel)
  }

  // テストで共通利用する senderStream を構築する
  private func makeSenderStream(mediaChannel: MediaChannel) -> MediaStream {
    let nativeFactory = mediaChannel.peerChannel.nativePeerChannelFactory
    let nativeStream = nativeFactory.createNativeStream(streamId: "test-stream")
    return BasicMediaStream(peerChannel: mediaChannel.peerChannel, nativeStream: nativeStream)
  }

  // テストで共通利用する ScreenCaptureSettings を構築する
  private func makeSettings() -> ScreenCaptureSettings {
    ScreenCaptureSettings()
  }

  /// capture A の開始後に、capture A の frame は送信でき、capture A を停止すると
  /// 送信できないことを確認する
  ///
  /// isActiveCaptureID は「context が保持する capture ID」(capture A) と
  /// 現在の activeCaptureID を照合する。stop で activeCaptureID が nil になると、
  /// 送信直前の照合で capture A の frame が拒否される。
  func testFrameForStoppedCaptureIsRejected() throws {
    let (controller, mediaChannel) = makeScreenCaptureController()
    let senderStream = makeSenderStream(mediaChannel: mediaChannel)

    // capture A を開始する
    let captureAID = try controller.beginStartCapture(
      settings: makeSettings(),
      senderStream: senderStream)

    // capture A の frame は送信できる (送信直前の照合で一致)
    XCTAssertTrue(
      controller.isActiveCaptureID(captureAID),
      "実行中の capture の frame は送信できること")

    // capture A を停止する (activeCaptureID が nil になる)
    XCTAssertTrue(
      controller.beginStopCapture(),
      "停止が受理されること")
    controller.completeStopCapture()

    // 停止後の capture A の frame は送信できない
    XCTAssertFalse(
      controller.isActiveCaptureID(captureAID),
      "停止した capture の frame は送信できないこと")
  }

  /// capture A を停止して capture B を再開始した後、capture A の frame は送信できず、
  /// capture B の frame は送信できることを確認する
  ///
  /// 停止→再開始の競合では、isReadyToSend() が実行時点の captureState しか確認しないため、
  /// 再実行後に .running になった state では旧 capture の frame を識別できない。
  /// capture ID の照合で旧 capture (capture A) の送信を拒否し、新 capture (capture B) のみ
  /// 送信できることを検証する。beginStopCapture + completeStopCapture で
  /// 停止完了 (state = .stopped) を再現し、その後に beginStartCapture を呼ぶことで
  /// 実再開始のイベント列を入力する。
  func testFrameForRestartedCaptureIsRejected() throws {
    let (controller, mediaChannel) = makeScreenCaptureController()
    let senderStream = makeSenderStream(mediaChannel: mediaChannel)

    // capture A を開始し、完了させる (state = .running)
    let captureAID = try controller.beginStartCapture(
      settings: makeSettings(),
      senderStream: senderStream)
    if case .success = controller.completeStartCapture(captureID: captureAID, error: nil) {
    } else {
      XCTFail("capture A の開始が完了すること")
    }

    // capture A を停止し、停止完了させる (state = .stopped)
    XCTAssertTrue(
      controller.beginStopCapture(),
      "capture A の停止が受理されること")
    controller.completeStopCapture()

    // capture B を即時再開始し、完了させる (state = .running)
    let captureBID = try controller.beginStartCapture(
      settings: makeSettings(),
      senderStream: senderStream)
    XCTAssertNotEqual(captureBID, captureAID, "capture B の ID は A と異なること")
    if case .success = controller.completeStartCapture(captureID: captureBID, error: nil) {
    } else {
      XCTFail("capture B の開始が完了すること")
    }

    // capture A の frame は送信できない (旧 capture)
    XCTAssertFalse(
      controller.isActiveCaptureID(captureAID),
      "再開始後の旧 capture の frame は送信できないこと")
    // capture B の frame は送信できる (現行 capture)
    XCTAssertTrue(
      controller.isActiveCaptureID(captureBID),
      "再開始後の新 capture の frame は送信できること")
  }

  /// 現在の capture ID と一致しない frame は送信できないことを確認する
  ///
  /// 照合関数に「現在の capture ではない ID」を渡した場合に拒否されることを検証する。
  func testFrameForMismatchedCaptureIDIsRejected() throws {
    let (controller, mediaChannel) = makeScreenCaptureController()
    let senderStream = makeSenderStream(mediaChannel: mediaChannel)

    let captureAID = try controller.beginStartCapture(
      settings: makeSettings(),
      senderStream: senderStream)

    // 現在の capture ID と一致しない ID (次世代の ID と想定) は拒否される
    XCTAssertFalse(
      controller.isActiveCaptureID(captureAID + 1),
      "現在の capture と一致しない ID の frame は送信できないこと")
  }
}
