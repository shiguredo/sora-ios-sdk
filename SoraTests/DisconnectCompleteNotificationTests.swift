import XCTest

@testable import Sora

/// MediaChannel の切断処理完了通知 (onDisconnectComplete) の判定ロジックのテスト
final class DisconnectCompleteNotificationTests: XCTestCase {

  // MARK: - shouldNotifyDisconnectComplete のテスト

  // 3 フラグの取り得る 8 組のうち、不変条件
  // (onDisconnectCompleteNotified == true には basicDisconnectCompleted == true
  // かつ onDisconnectNotified == true が必要) を満たさない 3 組は到達不能のため、
  // 到達可能な 5 組を検証する。

  // basicDisconnect() も onDisconnect も発火していない場合は発火しないことを確認する。
  func testShouldNotifyDisconnectCompleteWhenNothingHappened() {
    let result = MediaChannel.shouldNotifyDisconnectComplete(
      basicDisconnectCompleted: false,
      onDisconnectNotified: false,
      onDisconnectCompleteNotified: false)
    XCTAssertFalse(result, "basicDisconnect() と onDisconnect の両方が未発火の場合は発火しないこと")
  }

  // onDisconnect が発火していなくても basicDisconnect() が実行された場合は発火しないことを
  // 確認する (onDisconnect より先には発火しない)。
  // (同期パス: basicDisconnect() 実行時に onDisconnect はまだ発火していない)
  func testShouldNotifyDisconnectCompleteWhenBasicDisconnectFirst() {
    let result = MediaChannel.shouldNotifyDisconnectComplete(
      basicDisconnectCompleted: true,
      onDisconnectNotified: false,
      onDisconnectCompleteNotified: false)
    XCTAssertFalse(result, "onDisconnect 発火前は basicDisconnect() 完了済みでも発火しないこと")
  }

  // basicDisconnect() が未完了でも onDisconnect が発火している場合は発火しないことを確認する。
  // (遅延パス: 進行中の非同期処理が完了して basicDisconnect() が実行されるまでは発火しない)
  func testShouldNotifyDisconnectCompleteWhenOnDisconnectFirst() {
    let result = MediaChannel.shouldNotifyDisconnectComplete(
      basicDisconnectCompleted: false,
      onDisconnectNotified: true,
      onDisconnectCompleteNotified: false)
    XCTAssertFalse(result, "basicDisconnect() 完了前は onDisconnect 発火済みでも発火しないこと")
  }

  // basicDisconnect() と onDisconnect の両方が成立した場合に発火することを確認する。
  func testShouldNotifyDisconnectCompleteWhenBothCompleted() {
    let result = MediaChannel.shouldNotifyDisconnectComplete(
      basicDisconnectCompleted: true,
      onDisconnectNotified: true,
      onDisconnectCompleteNotified: false)
    XCTAssertTrue(result, "basicDisconnect() 完了と onDisconnect 発火が成立した場合は発火すること")
  }

  // 発火済みの場合は発火しないことを確認する (二重発火の防止)。
  func testShouldNotifyDisconnectCompleteAfterNotified() {
    let result = MediaChannel.shouldNotifyDisconnectComplete(
      basicDisconnectCompleted: true,
      onDisconnectNotified: true,
      onDisconnectCompleteNotified: true)
    XCTAssertFalse(result, "発火済みの場合は発火しないこと")
  }
}
