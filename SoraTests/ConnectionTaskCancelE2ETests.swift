import XCTest

@testable @preconcurrency import Sora

/// ConnectionTask の即時キャンセルに関する E2E テスト
///
/// 接続完了キャンセルの競合は接続タイミングに依存するため、単発ではなく反復して検証する。
final class ConnectionTaskCancelE2ETests: E2ETestBase {
  /// connect() の戻り値を直ちにキャンセルしても、接続が開始されないことを確認する
  ///
  /// バックグラウンド側の basicConnect が attach(peerChannel:) を実行する前に
  /// cancel() が呼ばれた場合、従来は peerChannel が nil のため切断処理が実行されず、
  /// 接続処理が開始された。競合タイミングを高めるため、反復して検証する。
  func testImmediateCancelDoesNotStartConnection() throws {
    var config = try buildConfiguration(role: .sendonly)
    // 接続時の物理カメラ自動起動を抑止する (接続キャンセルの検証に限定し、カメラを不要にする)
    config.initialCameraEnabled = false
    config.audioEnabled = false

    var connectCallbackCount = 0

    for _ in 0..<10 {
      let expectation = self.expectation(description: "接続キャンセルが完了すること")
      let task = sora?.connect(configuration: config) { _, error in
        // キャンセル成立時は connectionCancelled エラーが通知される。
        // それ以外のエラー (接続失敗) もキャンセルと同時に通知され得るため許容するが、
        // 成功 (nil) が返ってはいけない
        connectCallbackCount += 1
        if error == nil {
          XCTFail("キャンセル後に接続成功が通知された")
        }
      }

      // 別の待機処理を挟まず直ちにキャンセルする
      task?.cancel()

      // キャンセル処理が完了するまで待つ (即時キャンセルは WebSocket 未接続のため
      // 完了が同期ではない場合がある。短い待機で成立する)
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        expectation.fulfill()
      }
      wait(for: [expectation], timeout: 5)

      // 接続が残っていないこと (キャンセルされなかった場合は mediaChannels に残る)
      XCTAssertEqual(
        sora?.mediaChannels.count ?? 0, 0,
        "キャンセルした接続が mediaChannels に残っていないこと (iteration: \(connectCallbackCount))")
    }
  }

  /// キャンセル後に接続成功コールバックが発火しないことを確認する
  ///
  /// キャンセル処理中に接続完了が競合した場合、従来は .canceled が .completed に上書きされた。
  /// expectation の fulfill は接続コールバックからではなく、0.5 秒後の state 確認でのみ行う
  /// (両方から fulfill すると XCTest の API violation になるため)。
  func testCanceledStateIsNotOverwrittenByCompleted() throws {
    var config = try buildConfiguration(role: .sendonly)
    config.initialCameraEnabled = false
    config.audioEnabled = false

    let cancellationExpectation = self.expectation(
      description: "キャンセル完了後に state が canceled であること")

    let task = sora?.connect(configuration: config) { _, error in
      // キャンセル成立時は connectionCancelled エラーが通知される。
      // 成功 (nil) が返ってはいけない。
      if error == nil {
        XCTFail("キャンセル後に接続成功が通知された")
      }
    }

    // 接続開始の有無にかかわらず、キャンセルを実行する
    task?.cancel()

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      XCTAssertEqual(
        task?.state, .canceled,
        "キャンセル済みの ConnectionTask の state が canceled に保持されていること")
      cancellationExpectation.fulfill()
    }
    wait(for: [cancellationExpectation], timeout: 5)
  }
}
