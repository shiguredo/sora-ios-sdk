import XCTest

@testable import Sora

/// `CameraVideoCapturer.handlers` の差し替えと in-place 変更を検証します。
///
/// `CameraVideoCapturer.handlers` は型全体で共有する static なアクセサであり、
/// `CameraHandlersStorage` が参照の get / set を排他しつつ、差し替えない限り同じ instance を
/// 返します。そのため `CameraVideoCapturer.handlers.onCapture = ...` という in-place 変更が
/// 維持され、差し替えた場合は次の get から新しい instance が返ります。
final class CameraVideoCapturerHandlersTests: XCTestCase {
  /// 差し替えと in-place 変更が維持されることを確認します。
  ///
  /// 型全体で共有する状態のため、検証は専用の instance を差し替えてから行い、最後に元へ戻す。
  /// 元の instance に in-place 変更を加えると、参照を戻しても closure が残ってテスト間で漏れる。
  func testHandlersStoragePublishesBagAndKeepsInPlaceChanges() {
    let original = CameraVideoCapturer.handlers
    let subject = CameraVideoCapturerHandlers()
    CameraVideoCapturer.handlers = subject
    defer { CameraVideoCapturer.handlers = original }

    // in-place 変更は get が返した同じ instance に対して行われるため、設定した closure が読める。
    let handlers = CameraVideoCapturer.handlers
    XCTAssertTrue(handlers === subject, "差し替えた instance が返ること")
    handlers.onCapture = { _, frame in frame }
    XCTAssertNotNil(CameraVideoCapturer.handlers.onCapture, "in-place 変更が維持されること")

    // 差し替えると、次の get は新しい instance を返す。
    let replacement = CameraVideoCapturerHandlers()
    CameraVideoCapturer.handlers = replacement
    XCTAssertTrue(CameraVideoCapturer.handlers === replacement, "差し替えた instance が返ること")
    XCTAssertNil(CameraVideoCapturer.handlers.onCapture, "新しい instance の closure は未設定であること")
  }
}
