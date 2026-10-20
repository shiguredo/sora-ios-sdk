import UIKit
import XCTest

@testable import Sora

/// `VideoView.start()` の `isRendering` 更新を検証するユニットテスト
///
/// renderer callback は main queue から呼ばれるため、`start()` は main queue 上で `isRendering` を
/// 同期で `true` にします。`DispatchQueue.main.async` を 1 hop 挟む実装に戻すと、`onAdded` の直後に
/// 配送された frame が `isRendering == false` で破棄される回帰になるため、この更新の時点を
/// CI で固定します。
///
/// 描画そのもの (実際に映像が表示されること) は key window に依存するため CI では検証せず、
/// 実機で確認します。
@MainActor
final class VideoViewStartTests: XCTestCase {
  /// main queue 上で `start()` が `isRendering` を即時に更新することを確認する
  func testStartSetsIsRenderingSynchronouslyOnMainQueue() {
    let view = VideoView(frame: .zero)
    XCTAssertFalse(view.isRendering, "生成直後は描画していないこと")
    XCTAssertTrue(Thread.isMainThread, "main queue 上で検査すること")

    view.start()
    XCTAssertTrue(
      view.isRendering, "main queue 上では start() が isRendering を同期で true にすること")

    // start() は bringSubviewToFront を main queue へ非同期に積む。contentView の遅延読み込み
    // (nib) をこのテスト内で完了させ、失敗を別のテストへ漏らさないようにする。
    let started = XCTestExpectation(description: "start() の非同期処理を待つ")
    DispatchQueue.main.async {
      started.fulfill()
    }
    XCTAssertEqual(
      XCTWaiter().wait(for: [started], timeout: 5), .completed,
      "start() の非同期処理が制限時間内に完了すること")

    view.stop()
    XCTAssertFalse(view.isRendering, "stop() が isRendering を false にすること")
  }
}
