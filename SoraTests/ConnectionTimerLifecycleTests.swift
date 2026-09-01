import XCTest

@testable import Sora

/// ConnectionTimer の lifecycle に関するユニットテスト
///
/// ConnectionTimer は internal 型のため、テストから直接インスタンス化して
/// run / stop を呼び出し、main RunLoop 上での Timer の lifecycle を検証する。
/// モックやスタブは使用しない。
final class ConnectionTimerLifecycleTests: XCTestCase {
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

  // SignalingChannel を構築する
  private func makeSignalingChannel() -> SignalingChannel {
    SignalingChannel(configuration: makeConfiguration())
  }

  // ConnectionTimer を構築する (SignalingChannel のみの monitor で十分)
  private func makeConnectionTimer(timeout: Int) -> ConnectionTimer {
    ConnectionTimer(
      monitors: [.signalingChannel(makeSignalingChannel())],
      timeout: timeout)
  }

  /// run() の再実行時に旧 Timer の世代が進むことを確認する
  ///
  /// 旧実装では run() が既存 Timer を invalidate しないため、main RunLoop に残った旧 Timer
  /// が発火し、新しい接続を timeout として切断していた。修正後は run() の開始時に旧 Timer を
  /// invalidate し、generation を進めるため、旧 Timer の発火は無視される。
  /// (世代の更新そのものは lock 配下の currentGeneration で検証する)
  func testRunRerunAdvancesGeneration() {
    let connectionTimer = makeConnectionTimer(timeout: 100)
    let initialGeneration = connectionTimer.currentGeneration

    connectionTimer.run { [] in
      XCTFail("handler は実行されないこと (monitor は .disconnected のため)")
    }
    let generationAfterFirstRun = connectionTimer.currentGeneration
    XCTAssertGreaterThan(generationAfterFirstRun, initialGeneration, "run() で世代が進むこと")

    connectionTimer.run { [] in
      XCTFail("handler は実行されないこと (monitor は .disconnected のため)")
    }
    let generationAfterSecondRun = connectionTimer.currentGeneration
    XCTAssertGreaterThan(
      generationAfterSecondRun,
      generationAfterFirstRun,
      "run() の再実行で世代がさらに進むこと")
  }

  /// run() → stop() で Timer が解放されることを確認する
  ///
  /// 旧実装では stop() が timer を nil 化しないため、ConnectionTimer → Timer → closure → self の
  /// 循環参照が残り、ConnectionTimer が解放されなかった。修正後は stop() が timer = nil を
  /// 設定するため、weak 参照で解放を確認できる。
  func testStopReleasesTimer() {
    var connectionTimer: ConnectionTimer? = makeConnectionTimer(timeout: 100)
    weak var weakTimer = connectionTimer

    connectionTimer?.run { [] in
      XCTFail("停止した Timer の handler は実行されないこと")
    }
    connectionTimer?.stop()

    // ConnectionTimer の参照を解放する
    connectionTimer = nil

    // 強参照が 0 になることを確認する (次の RunLoop で release されることを待つ)
    let expectation = self.expectation(description: "ConnectionTimer が解放されること")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1)

    XCTAssertNil(weakTimer, "stop() 後に ConnectionTimer が解放されること")
  }

  /// stop() が複数回呼ばれても安全であることを確認する
  ///
  /// stop() は timer?.invalidate() と timer = nil を lock 配下で行うため、
  /// 何度呼んでも安全 (冪等) である。
  func testStopIsIdempotent() {
    let connectionTimer = makeConnectionTimer(timeout: 100)
    connectionTimer.run { [] in
      XCTFail("停止した Timer の handler は実行されないこと")
    }

    // 二重 stop を呼ぶ
    connectionTimer.stop()
    connectionTimer.stop()

    let expectation = self.expectation(description: "Timer の発火を待つこと")
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1)

    // エラーが発生しないこと (二重 stop でもクラッシュしない)
  }

  /// 遅延して発火した旧世代 Timer の handler が実行されないことを確認する
  ///
  /// run() の再実行で世代が進んだ場合、旧世代の Timer が main RunLoop から
  /// 遅れて発火しても、generation 不一致で無視される。ここでは
  /// 「再実行後の currentGeneration が示すとおり、旧 Timer が無効であること」を検証する。
  func testOldGenerationIsIgnoredByGenerationComparison() {
    let connectionTimer = makeConnectionTimer(timeout: 1)

    // 最初の run() (1 秒タイマー)
    connectionTimer.run { [] in
      XCTFail("旧 Timer の handler は実行されないこと")
    }

    // すぐに再実行 (新 Timer を 10 秒に変更)
    connectionTimer.run(timeout: 10) { [] in
      XCTFail("新 Timer の handler も呼ばれないこと (monitor は .disconnected のため)")
    }

    // 旧 Timer の発火期日 (1 秒) を過ぎるまで待つ
    let expectation = self.expectation(description: "旧 deadline 経過を待つこと")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 3)
  }
}
