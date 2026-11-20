// このファイルは `#if DEBUG` のテスト用アクセサに依存するため、Debug 構成でのみビルドできます。

import XCTest

@testable import Sora

/// `SoraLoggerOwner` の severity 更新と generation の契約を確認します。
///
/// 実際の `RTCCallbackLogger` を使い、stdout の捕捉は行いません。severity は `.none` にして
/// libwebrtc ログの出力を抑えます。
final class SoraLoggerOwnerTests: XCTestCase {
  /// severity の更新を並行に行っても generation が 1 回ずつ進むこと。
  func testConcurrentSetSeverityAdvancesGeneration() {
    let owner = SoraLoggerOwner()
    defer { owner.stop() }
    let iterations = 50

    DispatchQueue.concurrentPerform(iterations: iterations) { _ in
      owner.setSeverity(.none)
    }

    XCTAssertEqual(owner.currentGenerationForTesting, iterations, "更新のたびに generation が進むこと")
  }

  /// 古い generation の callback は出力されず、現在の generation だけが出力されること。
  func testStaleGenerationIsNotEmitted() {
    let owner = SoraLoggerOwner()
    defer { owner.stop() }
    owner.setSeverity(.none)
    let generation = owner.currentGenerationForTesting

    XCTAssertTrue(owner.shouldEmit(generation: generation), "現在の generation は出力できること")
    XCTAssertFalse(owner.shouldEmit(generation: generation - 1), "古い generation は出力しないこと")

    owner.setSeverity(.none)
    XCTAssertFalse(
      owner.shouldEmit(generation: generation), "severity を更新したら以前の generation は出力しないこと")
    XCTAssertTrue(
      owner.shouldEmit(generation: owner.currentGenerationForTesting), "現在の generation は出力できること")
  }

  /// stop すると generation が進み、停止前の generation の callback は出力されないこと。
  func testStopInvalidatesPreviousGeneration() {
    let owner = SoraLoggerOwner()
    defer { owner.stop() }
    owner.setSeverity(.none)
    let generation = owner.currentGenerationForTesting

    owner.stop()

    XCTAssertFalse(owner.shouldEmit(generation: generation), "停止前の generation は出力しないこと")
    XCTAssertEqual(owner.currentGenerationForTesting, generation + 1, "停止で generation が進むこと")
  }
}
