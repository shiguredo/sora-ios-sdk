import XCTest

@testable import Sora

/// `SoraCloseEvent.make(from:)` の変換規則のテスト
///
/// 切断完了の通知と切断クリーンアップのタイムアウト通知が同じ変換を使うため、
/// nil / WebSocket の close / DataChannel の close / その他の error の 4 分岐を固定する。
final class SoraCloseEventTests: XCTestCase {
  /// error が nil の場合は正常終了 (1000 / NO-ERROR) になることを確認する
  func testMakeFromNilReturnsNoError() {
    guard case .ok(let code, let reason) = SoraCloseEvent.make(from: nil) else {
      return XCTFail("error が nil の場合は .ok になること")
    }
    XCTAssertEqual(code, 1000, "code が 1000 であること")
    XCTAssertEqual(reason, "NO-ERROR", "reason が NO-ERROR であること")
  }

  /// WebSocket の close はステータスコードと理由を保持した .ok になることを確認する
  func testMakeFromWebSocketClosedReturnsOk() {
    let event = SoraCloseEvent.make(
      from: SoraError.webSocketClosed(statusCode: .abnormal, reason: "closed"))
    guard case .ok(let code, let reason) = event else {
      return XCTFail("WebSocket の close は .ok になること")
    }
    XCTAssertEqual(code, 1006, "ステータスコードが保持されること")
    XCTAssertEqual(reason, "closed", "理由が保持されること")
  }

  /// WebSocket の close で reason が nil の場合は空文字列になることを確認する
  func testMakeFromWebSocketClosedWithNilReasonReturnsEmptyReason() {
    let event = SoraCloseEvent.make(
      from: SoraError.webSocketClosed(statusCode: .normal, reason: nil))
    guard case .ok(let code, let reason) = event else {
      return XCTFail("WebSocket の close は .ok になること")
    }
    XCTAssertEqual(code, 1000, "ステータスコードが保持されること")
    XCTAssertEqual(reason, "", "reason が nil の場合は空文字列であること")
  }

  /// DataChannel の close はステータスコードと理由を保持した .ok になることを確認する
  func testMakeFromDataChannelClosedReturnsOk() {
    let event = SoraCloseEvent.make(
      from: SoraError.dataChannelClosed(statusCode: 4000, reason: "data channel closed"))
    guard case .ok(let code, let reason) = event else {
      return XCTFail("DataChannel の close は .ok になること")
    }
    XCTAssertEqual(code, 4000, "ステータスコードが保持されること")
    XCTAssertEqual(reason, "data channel closed", "理由が保持されること")
  }

  /// WebSocket / DataChannel の close 以外の SoraError は .error になることを確認する
  func testMakeFromOtherSoraErrorReturnsError() {
    let event = SoraCloseEvent.make(from: SoraError.connectionTimeout)
    guard case .error(let error) = event else {
      return XCTFail("その他の SoraError は .error になること")
    }
    guard let soraError = error as? SoraError, case .connectionTimeout = soraError else {
      return XCTFail("元の SoraError が保持されること")
    }
  }

  /// SoraError ではない error は .error になることを確認する
  func testMakeFromNonSoraErrorReturnsError() {
    let error = NSError(domain: "test", code: 1)
    guard case .error(let received) = SoraCloseEvent.make(from: error) else {
      return XCTFail("SoraError ではない error は .error になること")
    }
    XCTAssertEqual((received as NSError).domain, "test", "元の error が保持されること")
    XCTAssertEqual((received as NSError).code, 1, "元の error が保持されること")
  }
}
