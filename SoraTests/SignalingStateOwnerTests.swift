import XCTest

@testable import Sora

/// SignalingStateOwner の entry point 投入 (enqueue) のユニットテスト
///
/// SignalingChannel の entry point は owner の直列 queue へ投入して実行する。
/// このとき queue 外から同期で待つとデッドロックするため、投入が呼び出し元を
/// ブロックしないことを検証する。
///
/// URLSession の delegateQueue に owner と同じ直列 queue を設定しても、
/// queue 外から呼ばれる entry point は直列化だけでは保護されない。
/// owner queue は RTCPeerConnection の API 呼び出しで libwebrtc の signaling thread を
/// 待つことがあり、その signaling thread は RTCPeerConnectionDelegate の callback から
/// SignalingChannel.send を呼ぶ。つまり owner queue と signaling thread が相互に
/// 待ち合う関係になるため、queue 外からの同期 wait はデッドロックする。
/// これが「delegate queue の直列化だけでは entry point 全体を保護できない」理由である。
final class SignalingStateOwnerTests: XCTestCase {
  /// queue 外からの enqueue が呼び出し元をブロックしないことを確認する
  ///
  /// owner queue 上で「別スレッドの完了を待つ」処理を実行している間に、
  /// queue 外から enqueue しても呼び出し元が停止しないことを検証する。
  /// 同期 wait の実装では、この検証はタイムアウトして失敗する。
  func testEnqueueFromOutsideDoesNotBlockCaller() {
    let owner = SignalingStateOwner()
    let blockingStarted = expectation(description: "owner queue 上の処理が開始すること")
    let releaseBlocking = DispatchSemaphore(value: 0)

    // owner queue 上で「別スレッドの完了を待つ」処理を実行する。
    // 実際の SDK では RTCPeerConnection の API が libwebrtc の signaling thread を
    // 待つのがこれに相当する。
    owner.enqueue {
      blockingStarted.fulfill()
      releaseBlocking.wait()
    }
    wait(for: [blockingStarted], timeout: 3)

    // owner queue が別スレッド待ちの間に queue 外から enqueue しても、
    // 呼び出し元は owner queue の完了を待たない。
    let returned = expectation(description: "enqueue が呼び出し元をブロックせずに戻ること")
    DispatchQueue.global().async {
      owner.enqueue {}
      returned.fulfill()
    }
    wait(for: [returned], timeout: 3)

    // owner queue を解放して後始末する
    releaseBlocking.signal()
  }

  /// owner queue 上からの enqueue がその場で実行されることを確認する
  ///
  /// delegate callback や handler から操作 API を呼ぶ再入経路で、
  /// queue へ再投入してデッドロックしないことを検証する。
  func testEnqueueOnOwnerQueueRunsInline() {
    let owner = SignalingStateOwner()
    let expectation = expectation(description: "owner queue 上の再入が完了すること")
    var didRunInner = false
    var ranInline = false

    owner.enqueue {
      owner.enqueue {
        didRunInner = true
      }
      // queue 上からの enqueue はその場で実行されるため、この時点で完了している
      ranInline = didRunInner
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 3)
    XCTAssertTrue(didRunInner, "owner queue 上の再入が実行されること")
    XCTAssertTrue(ranInline, "owner queue 上の再入はその場で実行されること")
  }

  /// URLSession delegate callback 相当 (owner.queue 上の操作) からの再入が
  /// その場で実行されることを確認する
  func testEnqueueOnDelegateQueueRunsInline() {
    let owner = SignalingStateOwner()
    let expectation = expectation(description: "delegate queue 上の再入が完了すること")

    owner.queue.addOperation {
      owner.enqueue {
        owner.handle(.connectRequested)
      }
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 3)
    XCTAssertEqual(owner.snapshot.state.phase, .connecting)
  }

  /// 別スレッドからの enqueue でも状態を更新できることを確認する
  func testEnqueueFromOtherThreadUpdatesState() {
    let owner = SignalingStateOwner()
    let expectation = expectation(description: "別スレッドからの操作が完了すること")

    DispatchQueue.global().async {
      owner.enqueue {
        owner.handle(.connectRequested)
        expectation.fulfill()
      }
    }

    wait(for: [expectation], timeout: 3)
    XCTAssertEqual(owner.snapshot.state.phase, .connecting)
  }

  /// enqueue した順に処理されることを確認する
  ///
  /// 非同期で投入しても、単一の直列 queue へ投入する限り entry point の順序は保たれる。
  func testEnqueuePreservesSubmissionOrder() {
    let owner = SignalingStateOwner()
    let total = 20
    let expectation = expectation(description: "投入した順に実行されること")
    var observed: [Int] = []

    for index in 0..<total {
      owner.enqueue {
        observed.append(index)
        if observed.count == total {
          expectation.fulfill()
        }
      }
    }

    wait(for: [expectation], timeout: 3)
    XCTAssertEqual(observed, Array(0..<total), "enqueue した順に実行されること")
  }

  // MARK: - 接続完了 handler のライフサイクル

  /// 接続成功の通知で handler が消費されないことを確認する
  ///
  /// redirect では新しい transport が採用されたときにも同じ handler を呼び、
  /// type: connect を redirect: true で再送する。接続成功時に handler を
  /// take-and-clear すると 2 回目の採用で handler が nil になり、redirect が
  /// 機能しなくなる。
  func testOnConnectHandlerIsNotConsumedByNotification() {
    let owner = SignalingStateOwner()
    let expectation = expectation(description: "接続成功の通知が 2 回呼ばれること")
    var callCount = 0

    owner.enqueue {
      owner.setOnConnect { _ in
        callCount += 1
        if callCount == 2 {
          expectation.fulfill()
        }
      }

      // 初回接続の採用
      owner.onConnectOnQueue()?(nil)
      // redirect 後の採用 (同じ handler をもう一度呼ぶ)
      owner.onConnectOnQueue()?(nil)
    }

    wait(for: [expectation], timeout: 3)
    XCTAssertEqual(callCount, 2, "接続成功のたびに handler が呼ばれること")
  }

  /// takeOnConnect が handler を消費することを確認する
  ///
  /// 終端経路 (CA 証明書のパース失敗など) では 1 回だけ通知して解放する。
  func testTakeOnConnectConsumesHandler() {
    let owner = SignalingStateOwner()
    let expectation = expectation(description: "handler の取り出しが完了すること")
    var firstIsNil = true
    var secondIsNil = false

    owner.enqueue {
      owner.setOnConnect { _ in }
      firstIsNil = owner.takeOnConnect() == nil
      secondIsNil = owner.takeOnConnect() == nil
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 3)
    XCTAssertFalse(firstIsNil, "1 回目は handler を取り出せること")
    XCTAssertTrue(secondIsNil, "2 回目は nil になること")
  }
}
