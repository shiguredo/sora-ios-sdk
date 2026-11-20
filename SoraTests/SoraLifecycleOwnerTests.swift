// このファイルは `#if DEBUG` のテスト用アクセサに依存するため、Debug 構成でのみビルドできます。

import XCTest

@testable import Sora

/// `SoraLifecycleOwner` の接続登録数と finish 状態の遷移を確認します。
///
/// process-wide な `SoraLifecycleOwner.shared` は使わず、テストごとに新しい instance を使います。
/// 実際の WebRTC の cleanup は実行しません。
final class SoraLifecycleOwnerTests: XCTestCase {
  /// 登録を解除すると登録数が減り、同じ登録の二重解除は無視されること。
  func testRegistrationIsReleasedOnlyOnce() {
    let owner = SoraLifecycleOwner()

    guard case .registered(let first) = owner.beginRegistration() else {
      return XCTFail("終了状態ではないため登録できること")
    }
    guard case .registered(let second) = owner.beginRegistration() else {
      return XCTFail("終了状態ではないため登録できること")
    }
    XCTAssertEqual(owner.registrationCount, 2)

    first.end()
    // 二重解除は登録数に影響しない。
    first.end()
    XCTAssertEqual(owner.registrationCount, 1)

    second.end()
    XCTAssertEqual(owner.registrationCount, 0)
  }

  /// 登録トークンの参照がすべてなくなると、`deinit` で登録が解除されること。
  func testRegistrationIsReleasedWhenTokenIsDeallocated() {
    let owner = SoraLifecycleOwner()

    do {
      guard case .registered(let registration) = owner.beginRegistration() else {
        return XCTFail("終了状態ではないため登録できること")
      }
      XCTAssertEqual(owner.registrationCount, 1)
      withExtendedLifetime(registration) {}
    }
    XCTAssertEqual(owner.registrationCount, 0, "トークンの解放で登録が解除されること")
  }

  /// 登録中は finish できず、すべて解除すると finish できること。
  func testFinishIsBusyWhileRegistered() {
    let owner = SoraLifecycleOwner()

    guard case .registered(let registration) = owner.beginRegistration() else {
      return XCTFail("終了状態ではないため登録できること")
    }

    guard case .busy(let registrationCount) = owner.beginFinish() else {
      return XCTFail("登録中は cleanup できないこと")
    }
    XCTAssertEqual(registrationCount, 1, "busy の理由に登録数が入ること")
    // busy を返しても終了状態にはならない。
    guard case .busy = owner.beginFinish() else {
      return XCTFail("busy の後も登録中は cleanup できないこと")
    }

    registration.end()
    guard case .proceed = owner.beginFinish() else {
      return XCTFail("登録がない場合は cleanup できること")
    }

    // 2 回目の finish は何もしない。
    guard case .alreadyFinished = owner.beginFinish() else {
      return XCTFail("2 回目の finish は alreadyFinished であること")
    }
    // 終了状態では新しい登録を受け付けない。
    guard case .finished = owner.beginRegistration() else {
      return XCTFail("終了状態では登録できないこと")
    }
  }

  /// 登録がない状態では、最初の finish だけが cleanup を許可すること。
  func testFinishWithoutRegistrationProceedsOnce() {
    let owner = SoraLifecycleOwner()

    guard case .proceed = owner.beginFinish() else {
      return XCTFail("登録がない場合は cleanup できること")
    }
    guard case .alreadyFinished = owner.beginFinish() else {
      return XCTFail("2 回目の finish は alreadyFinished であること")
    }
  }

  /// 登録と解除を並行に行っても、すべて解除された後にだけ finish できること。
  func testConcurrentRegistrationsAreReleased() {
    let owner = SoraLifecycleOwner()
    let failures = FailureCounter()

    DispatchQueue.concurrentPerform(iterations: 200) { _ in
      switch owner.beginRegistration() {
      case .registered(let registration):
        registration.end()
      case .finished:
        failures.increment()
      }
    }

    XCTAssertEqual(failures.count, 0, "終了状態ではないためすべての登録ができること")
    XCTAssertEqual(owner.registrationCount, 0)
    guard case .proceed = owner.beginFinish() else {
      return XCTFail("すべての登録が解除されたら cleanup できること")
    }
  }
}

/// 並行実行中の失敗を数えるための、lock 付きカウンタです。
private final class FailureCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  /// 失敗を 1 回数えます。
  func increment() {
    lock.lock()
    value += 1
    lock.unlock()
  }

  /// 数えた失敗の数です。
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}
