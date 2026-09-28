import XCTest

@testable import Sora

/// DummyVideoCapturer の単体テスト
///
/// `DummyVideoCapturer` は MainActor に隔離されているため、テストも MainActor で実行する
@MainActor
final class DummyVideoCapturerTests: XCTestCase {

  func testStartStopTogglesIsRunning() {
    let capturer = DummyVideoCapturer(width: 640, height: 480, frameRate: 30)
    XCTAssertFalse(capturer.isRunning)
    capturer.start()
    // stream 未設定でも Timer は起動される
    XCTAssertTrue(capturer.isRunning)
    capturer.stop()
    XCTAssertFalse(capturer.isRunning)
  }

  func testStartDuplicateIgnored() {
    let capturer = DummyVideoCapturer(width: 640, height: 480, frameRate: 30)
    capturer.start()
    capturer.start()
    // 重複呼び出しは無視され、isRunning は true のまま
    XCTAssertTrue(capturer.isRunning)
    capturer.stop()
  }

  func testStopDuplicateIgnored() {
    let capturer = DummyVideoCapturer(width: 640, height: 480, frameRate: 30)
    capturer.stop()
    XCTAssertFalse(capturer.isRunning)
  }

  func testInitClampsDimensions() {
    let capturer = DummyVideoCapturer(width: 0, height: -1, frameRate: 0)
    // 0 以下は 1 に、かつ奇数は偶数に切り上げ → 2
    XCTAssertEqual(capturer.width, 2)
    XCTAssertEqual(capturer.height, 2)
    // 1 未満は 1 にクランプ
    XCTAssertEqual(capturer.frameRate, 1)
  }

  func testInitRoundsOddToEven() {
    let capturer = DummyVideoCapturer(width: 641, height: 479, frameRate: 30)
    XCTAssertEqual(capturer.width, 642)
    XCTAssertEqual(capturer.height, 480)
  }

  func testInitClampsFrameRateMax() {
    let capturer = DummyVideoCapturer(width: 640, height: 480, frameRate: 200)
    XCTAssertEqual(capturer.frameRate, 120)
  }

  /// Timer の block が main RunLoop 上で発火して `onTimer` が実 stream へ frame を送信し、
  /// `stop()` で発火が止まることを確認します。
  ///
  /// Timer の block は `@Sendable` のため `MainActor.assumeIsolated` で main 実行を表明しています。
  /// main 実行でなければ `MainActor.assumeIsolated` の precondition でテストプロセスが落ちます。
  /// 接続は行わず、テスト用の実 `MediaChannel` / `MediaStream` を使います (モックやスタブは
  /// 使用しません)。
  /// `frameCount` は ingress へ投入した数であり、配送の完了を待った数ではありません。
  func testTimerCallbackSendsFramesUntilStop() throws {
    let mediaChannel = try makeTestMediaChannel()
    let stream = makeSenderStreamWithVideoTrack(mediaChannel: mediaChannel)
    let capturer = DummyVideoCapturer(width: 640, height: 480, frameRate: 30)
    capturer.stream = stream
    capturer.start()

    // 30 fps では 33 ms ごとに発火します。main RunLoop を回さないと Timer は発火しないため、
    // frame が 2 つ投入されるまで (上限 5 秒) main RunLoop を回します。2 つ待つのは、
    // Timer が repeating であること (1 回で止まらないこと) まで確認するためです
    let deadline = Date().addingTimeInterval(5)
    while capturer.frameCount < 2 && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    XCTAssertGreaterThanOrEqual(capturer.frameCount, 2, "repeating な Timer が frame を送信すること")
    XCTAssertTrue(capturer.isRunning, "frame 送信後も動作中であること")

    capturer.stop()
    let frameCountAfterStop = capturer.frameCount
    // stop 後に main RunLoop を回しても frame が増えないことを確認します。invalidate が
    // 漏れていると repeating Timer が発火し続けるため、この比較で検出できます
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    XCTAssertEqual(
      capturer.frameCount, frameCountAfterStop, "stop 後は frame を送信しないこと")
  }

  /// stop を呼ばずに解放した場合も、capturer が解放されることを確認します。
  ///
  /// `deinit` は `isolated` のため MainActor 上で実行されます。実行の完了を待ってから
  /// weak 参照を確認するため、main queue を drain します。
  ///
  /// `deinit` の `timer?.invalidate()` 自体は直接観測できません。Timer の block は `self` を
  /// weak で capture するため、無効化されなくても capturer は解放され、発火しても何も起きない
  /// ためです。Timer の無効化は `stop()` の経路
  /// (`testTimerCallbackSendsFramesUntilStop`) で確認します。
  func testDeinitWithoutStopReleasesCapturer() {
    weak var weakCapturer: DummyVideoCapturer?
    autoreleasepool {
      let capturer = DummyVideoCapturer(width: 640, height: 480, frameRate: 30)
      capturer.start()
      weakCapturer = capturer
      // stop を呼ばずに autoreleasepool を抜ける
    }
    // MainActor 上の deinit の実行を待つ
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    XCTAssertNil(weakCapturer, "deinit が実行されること")
  }
}
