import AVFoundation
import WebRTC
import XCTest

@testable import Sora

/// `SoraInstanceStateOwner` の route 変更の配送と delegate 解除を確認します。
///
/// モックやスタブは使わず、実 `RTCAudioSession` と実 `SoraHandlers` を使います。
final class SoraInstanceStateOwnerTests: XCTestCase {
  /// 経路変更が `SoraHandlers.onChangeAudioRoute` へ 1 回配送されること。
  func testRouteChangeIsDeliveredToHandlers() {
    let handlers = SoraHandlers()
    let owner = SoraInstanceStateOwner(handlers: handlers, publisher: SoraEventPublisher())
    let session = RTCAudioSession.sharedInstance()
    var callCount = 0
    var receivedReason: AVAudioSession.RouteChangeReason?
    handlers.onChangeAudioRoute = { receivedSession, reason, _ in
      XCTAssertIdentical(receivedSession, session, "通知元の session が渡ること")
      callCount += 1
      receivedReason = reason
    }

    owner.audioSessionDelegateAdapter.audioSessionDidChangeRoute(
      session,
      reason: .categoryChange,
      previousRoute: session.currentRoute)

    XCTAssertEqual(callCount, 1, "handler が 1 回だけ呼ばれること")
    XCTAssertEqual(receivedReason, .categoryChange, "変更理由が渡ること")
  }

  /// 経路変更が `SoraEventKind.audioRouteChanged` として購読者へ配送されること。
  func testRouteChangeIsPublishedAsEvent() {
    let publisher = SoraEventPublisher()
    let owner = SoraInstanceStateOwner(handlers: SoraHandlers(), publisher: publisher)
    let received = expectation(description: "audioRouteChanged が配送されること")
    let stream = publisher.subscribe(bufferingPolicy: .bufferingNewest(8))
    let consumer = Task {
      for await event in stream where event.kind == .audioRouteChanged {
        XCTAssertEqual(event.audioRoute?.reason, .categoryChange, "変更理由が渡ること")
        received.fulfill()
        return
      }
    }

    let session = RTCAudioSession.sharedInstance()
    owner.audioSessionDelegateAdapter.audioSessionDidChangeRoute(
      session,
      reason: .categoryChange,
      previousRoute: session.currentRoute)

    wait(for: [received], timeout: 5)
    consumer.cancel()
  }

  /// delegate の解除を二重に呼んでもクラッシュしないこと。
  ///
  /// `RTCAudioSession` は登録済み delegate の一覧を公開しないため、解除の完了は直接観測できない。
  /// ここでは二重解除が例外・クラッシュにならないことだけを確認する。
  func testDetachIsIdempotent() {
    let owner = SoraInstanceStateOwner(handlers: SoraHandlers(), publisher: SoraEventPublisher())

    owner.detachAudioSessionDelegate()
    owner.detachAudioSessionDelegate()
  }
}
