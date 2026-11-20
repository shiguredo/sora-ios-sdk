import AVFoundation
import WebRTC
import XCTest

@testable import Sora

/// `SoraRTCAudioSessionDelegateAdapter` が経路変更を handler へ転送することと、
/// `.routeConfigurationChange` を無視することを確認します。
///
/// モックやスタブは使わず、実 `RTCAudioSession` の現在のルートを使って駆動します。
final class SoraRTCAudioSessionDelegateAdapterTests: XCTestCase {
  /// `.categoryChange` の通知が handler へ 1 回転送されること。
  func testCategoryChangeIsForwardedOnce() {
    let session = RTCAudioSession.sharedInstance()
    let previousRoute = session.currentRoute
    var callCount = 0
    var receivedReason: AVAudioSession.RouteChangeReason?
    var receivedRoute: AVAudioSessionRouteDescription?
    let adapter = SoraRTCAudioSessionDelegateAdapter { receivedSession, reason, route in
      XCTAssertIdentical(receivedSession, session, "通知元の session が渡ること")
      callCount += 1
      receivedReason = reason
      receivedRoute = route
    }

    adapter.audioSessionDidChangeRoute(
      session, reason: .categoryChange, previousRoute: previousRoute)

    XCTAssertEqual(callCount, 1, "handler が 1 回だけ呼ばれること")
    XCTAssertEqual(receivedReason, .categoryChange, "変更理由が渡ること")
    XCTAssertIdentical(receivedRoute, previousRoute, "変更前のルートが渡ること")
  }

  /// `.routeConfigurationChange` の通知は handler へ転送しないこと。
  func testRouteConfigurationChangeIsIgnored() {
    let session = RTCAudioSession.sharedInstance()
    var callCount = 0
    let adapter = SoraRTCAudioSessionDelegateAdapter { _, _, _ in
      callCount += 1
    }

    adapter.audioSessionDidChangeRoute(
      session,
      reason: .routeConfigurationChange,
      previousRoute: session.currentRoute)

    XCTAssertEqual(callCount, 0, "routeConfigurationChange は転送しないこと")
  }
}
