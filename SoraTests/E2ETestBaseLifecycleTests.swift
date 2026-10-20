import XCTest

@testable import Sora

/// `E2ETestBase` の async な `setUp` が同期の test method でも呼ばれることを確認するテスト
///
/// `E2ETestBase` は `@MainActor` で隔離しているため、初期化と後始末は async 版の
/// `setUp` / `tearDown` で行う。環境変数が未設定の実行では E2E テストがすべてスキップされるため、
/// 初期化が呼ばれないまま気付きにくくなる。このテストは実 Sora 接続を行わないため、
/// 環境変数が未設定でも実行される。`@MainActor` は `E2ETestBase` から継承する。
final class E2ETestBaseLifecycleTests: E2ETestBase {
  /// async な `setUp` が同期の test method でも呼ばれることを確認する
  ///
  /// `sora` は `setUp` の最後で設定されるため、これが非 nil であることが `setUp` の実行の
  /// 証拠になる
  func testSetUpRunsForSynchronousTestMethod() {
    XCTAssertNotNil(sora, "async な setUp が同期の test method でも呼ばれること")
    // 補助的な確認。Logger はプロセス共通の状態のため、単独では setUp 実行の証拠にならない
    XCTAssertEqual(
      Logger.shared.level, .warn, "setUp がログレベルを warn に設定していること")
  }

  /// async な `tearDown` の後始末が完了することを確認する
  ///
  /// `tearDown` 自体の呼び出しは、この override が呼ばれなければ assertion も評価されないため
  /// 検証できない。ここでは `super.tearDown()` の内容 (`sora` の解放) を確認する
  override func tearDown() async throws {
    try await super.tearDown()
    XCTAssertNil(sora, "async な tearDown が sora を解放すること")
  }
}
