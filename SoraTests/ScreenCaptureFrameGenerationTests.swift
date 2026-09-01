import XCTest

@testable import Sora

/// 画面共有の capture ID 世代管理に関するユニットテスト
///
/// 画面共有を停止して直ちに再開始したときに、停止前に送信キューへ投入された旧フレームが
/// 古い sender stream を使わないことを、capture ID の世代判定 (shouldSendFrameForCaptureID) で
/// 検証する。モックやスタブは使用しない。
final class ScreenCaptureFrameGenerationTests: XCTestCase {
  // テストで共通利用するシグナリング URL を返す
  private func makeTestURL() -> URL {
    guard let url = URL(string: "wss://example.com") else {
      fatalError("failed to create test URL")
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
  /// shouldSendFrameForCaptureID は「context が保持する capture ID」(capture A) と
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
      controller.shouldSendFrameForCaptureID(captureAID),
      "実行中の capture の frame は送信できること")

    // capture A を停止する (activeCaptureID が nil になる)
    XCTAssertTrue(controller.beginStopCapture())

    // 停止後の capture A の frame は送信できない
    XCTAssertFalse(
      controller.shouldSendFrameForCaptureID(captureAID),
      "停止した capture の frame は送信できないこと")
  }

  /// capture ID が一致しない frame は送信できないことを確認する
  ///
  /// 照合関数に「現在の capture ではない ID」を渡した場合に拒否されることを検証する。
  func testFrameForUnknownCaptureIDIsRejected() throws {
    let (controller, mediaChannel) = makeScreenCaptureController()
    let senderStream = makeSenderStream(mediaChannel: mediaChannel)

    let captureAID = try controller.beginStartCapture(
      settings: makeSettings(),
      senderStream: senderStream)

    // 未知の capture ID (現在と一致しない) は拒否される
    XCTAssertFalse(
      controller.shouldSendFrameForCaptureID(captureAID + 100),
      "未知の capture ID の frame は送信できないこと")
  }
}
