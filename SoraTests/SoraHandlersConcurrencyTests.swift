import XCTest

@testable import Sora

/// `SoraHandlers` の handler property の読み書きが並行してもデータ競合にならないことと、
/// 取得済みの snapshot を callback から呼んでも問題ないことを確認します。
///
/// モックやスタブは使わず、実際の `SoraHandlers` を操作します。
/// 並行アクセスのデータ競合検出は TSan を有効にしたビルドで行うことを前提にします。
final class SoraHandlersConcurrencyTests: XCTestCase {
  /// 5 つの handler property の get / set を並行に行っても、最後に設定した値が読めること。
  func testConcurrentHandlerBagReadWrite() {
    let handlers = SoraHandlers()

    DispatchQueue.concurrentPerform(iterations: 200) { index in
      switch index % 5 {
      case 0:
        handlers.onConnect = { _, _ in }
        _ = handlers.onConnect
      case 1:
        handlers.onDisconnect = { _, _ in }
        _ = handlers.onDisconnect
      case 2:
        handlers.onAddMediaChannel = { _ in }
        _ = handlers.onAddMediaChannel
      case 3:
        handlers.onRemoveMediaChannel = { _ in }
        _ = handlers.onRemoveMediaChannel
      default:
        handlers.onChangeAudioRoute = { _, _, _ in }
        _ = handlers.onChangeAudioRoute
      }
    }

    // 並行区間の後に設定した handler が、そのまま取得して実行できること。
    var invoked = false
    handlers.onConnect = { _, _ in invoked = true }
    let connectHandler = handlers.onConnect
    XCTAssertNotNil(connectHandler)
    connectHandler?(nil, nil)
    XCTAssertTrue(invoked, "設定した handler が取得できること")

    handlers.onDisconnect = { _, _ in }
    XCTAssertNotNil(handlers.onDisconnect)
    handlers.onAddMediaChannel = { _ in }
    XCTAssertNotNil(handlers.onAddMediaChannel)
    handlers.onRemoveMediaChannel = { _ in }
    XCTAssertNotNil(handlers.onRemoveMediaChannel)
    handlers.onChangeAudioRoute = { _, _, _ in }
    XCTAssertNotNil(handlers.onChangeAudioRoute)
  }

  /// 取得済みの handler の実行中に同じ property を差し替えても、snapshot を 1 回だけ呼べること。
  ///
  /// `HandlerStorage` の get は lock を解放してから値を返すため、callback の中から同じ property を
  /// 差し替えても deadlock しません。ここでは取得した handler が 1 回だけ呼ばれることを確認します。
  func testHandlerSnapshotCanBeReplacedFromCallback() {
    let handlers = SoraHandlers()
    let called = expectation(description: "snapshot の handler が 1 回だけ呼ばれること")
    called.assertForOverFulfill = true

    handlers.onConnect = { _, _ in
      // callback の中から同じ property を差し替える。lock を保持していないため再入できる。
      handlers.onConnect = { _, _ in }
      called.fulfill()
    }

    let snapshot = handlers.onConnect
    XCTAssertNotNil(snapshot)
    snapshot?(nil, nil)

    wait(for: [called], timeout: 1)
  }

  /// handler が何も設定されていない場合は nil を返し、呼び出し側で安全に扱えること。
  func testUnsetHandlersAreNil() {
    let handlers = SoraHandlers()
    XCTAssertNil(handlers.onConnect)
    XCTAssertNil(handlers.onDisconnect)
    XCTAssertNil(handlers.onAddMediaChannel)
    XCTAssertNil(handlers.onRemoveMediaChannel)
    XCTAssertNil(handlers.onChangeAudioRoute)
  }
}
