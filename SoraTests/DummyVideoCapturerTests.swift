import XCTest

@testable import Sora

/// DummyVideoCapturer の単体テスト
final class DummyVideoCapturerTests: XCTestCase {

  func testStartStopTogglesIsRunning() {
    let capturer = DummyVideoCapturer(width: 640, height: 480, frameRate: 30)
    // stream 未設定でも start は isRunning を true にしない
    XCTAssertFalse(capturer.isRunning)
    capturer.start()
    XCTAssertFalse(capturer.isRunning)
  }

  func testStartDuplicateIgnored() {
    let capturer = DummyVideoCapturer(width: 640, height: 480, frameRate: 30)
    capturer.start()
    capturer.start()
    XCTAssertFalse(capturer.isRunning)
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

  func testDeinitInvalidatesTimer() {
    var weakCapturer: DummyVideoCapturer?
    autoreleasepool {
      let capturer = DummyVideoCapturer(width: 640, height: 480, frameRate: 30)
      capturer.start()
      weakCapturer = capturer
      // stop を呼ばずに autoreleasepool を抜ける
    }
    // deinit が実行され弱参照が nil になる
    XCTAssertNil(weakCapturer)
    // 無効化された Timer が再発火しないことを確認するため RunLoop を回す
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
  }
}
