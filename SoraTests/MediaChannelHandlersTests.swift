import WebRTC
import XCTest

@testable import Sora

/// handler の呼び出し回数をスレッド安全に数えるテスト用のカウンタです。
///
/// handler は任意のスレッドから呼ばれるため、`NSLock` で排他して数えます。
private final class HandlerCallCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  /// 呼び出し回数を 1 増やします。
  func increment() {
    lock.lock()
    value += 1
    lock.unlock()
  }

  /// 現在の呼び出し回数です。
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

/// `MediaChannelHandlers` が接続ごとに独立し、`Configuration.mediaChannelHandlers` のインスタンスが
/// 接続の開始時にコピーされることを検証します。
///
/// モックやスタブは使わず、実際の `Configuration` / `MediaChannel` / `Sora` を使います。
/// 接続先には到達できない `.invalid` ドメインを使い、接続試行はテスト内で切断するため、
/// サーバーを必要としません。
final class MediaChannelHandlersTests: XCTestCase {
  /// 接続先に使う到達不能な URL
  ///
  /// `.invalid` は名前解決が必ず失敗する予約済みの TLD であり、誤って外部へ接続しない。
  private static let unreachableURL = URL(string: "wss://sora.invalid/signaling")!

  /// 待機に使う上限 (秒)
  private static let timeout: TimeInterval = 5

  /// テスト用の `Configuration` を構築します。
  ///
  /// handler の配送だけを検証するため、音声デバイスの初期化を伴わない設定にします。
  private func makeConfiguration() -> Configuration {
    var configuration = Configuration(
      urlCandidates: [Self.unreachableURL],
      channelId: "test",
      role: .recvonly)
    configuration.audioEnabled = false
    return configuration
  }

  /// `MediaChannel` に接続を開始させます。
  ///
  /// `onDisconnect` は `.connecting` または `.connected` の状態から `disconnect` したときだけ
  /// 配送されるため、テストでは生成した `MediaChannel` を `.connecting` にしてから切断します。
  ///
  /// - parameter mediaChannel: 接続を開始するメディアチャネル
  private func startConnecting(_ mediaChannel: MediaChannel) {
    _ = mediaChannel.connect(webRTCConfiguration: WebRTCConfiguration()) { _ in }
    XCTAssertEqual(mediaChannel.state, .connecting, "接続の開始直後の状態が .connecting であること")
  }

  /// コピー用イニシャライザが 10 個すべての handler property を写すことを確認する
  func testCopyingInitializerCopiesAllHandlerProperties() throws {
    let source = MediaChannelHandlers()
    // 呼ばれた handler を識別するため、closure ごとに異なる名前を記録する
    var invoked: [String] = []
    source.onConnect = { _ in invoked.append("onConnect") }
    source.onDisconnectLegacy = { _ in invoked.append("onDisconnectLegacy") }
    source.onDisconnect = { _ in invoked.append("onDisconnect") }
    source.onAddStream = { _ in invoked.append("onAddStream") }
    source.onRemoveStream = { _ in invoked.append("onRemoveStream") }
    source.onReceiveSignalingJSON = { _ in invoked.append("onReceiveSignalingJSON") }
    source.onReceiveSignaling = { _ in invoked.append("onReceiveSignaling") }
    source.onDataChannel = { _ in invoked.append("onDataChannel") }
    source.onDataChannelOpened = { _, _ in invoked.append("onDataChannelOpened") }
    source.onDataChannelMessage = { _, _, _ in invoked.append("onDataChannelMessage") }

    let copied = MediaChannelHandlers(copying: source)
    XCTAssertFalse(copied === source, "写し先が写し元と別の instance であること")

    // handler の呼び出しに必要な実オブジェクトを用意する
    let mediaChannel = try MediaChannel(configuration: makeConfiguration())
    let nativeStream = mediaChannel.peerChannel.nativePeerChannelFactory.createNativeStream(
      streamId: "test-stream")
    let stream = BasicMediaStream(
      peerChannel: mediaChannel.peerChannel,
      nativeStream: nativeStream)
    let signaling = try JSONDecoder().decode(
      Signaling.self,
      from: Data(#"{"type":"ping"}"#.utf8))

    // 写し先から 10 個すべての handler を呼び出し、写し元の closure が実行されることを確認する
    copied.onConnect?(nil)
    copied.onDisconnectLegacy?(nil)
    copied.onDisconnect?(.ok(code: 1000, reason: "normal"))
    copied.onAddStream?(stream)
    copied.onRemoveStream?(stream)
    copied.onReceiveSignalingJSON?("{}")
    copied.onReceiveSignaling?(signaling)
    copied.onDataChannel?(mediaChannel)
    copied.onDataChannelOpened?(mediaChannel, "#spam")
    copied.onDataChannelMessage?(mediaChannel, "#spam", Data("hello".utf8))

    XCTAssertEqual(
      invoked,
      [
        "onConnect", "onDisconnectLegacy", "onDisconnect", "onAddStream", "onRemoveStream",
        "onReceiveSignalingJSON", "onReceiveSignaling", "onDataChannel", "onDataChannelOpened",
        "onDataChannelMessage",
      ],
      "10 個すべての handler property が写されること")

    // 写し元の handler を外しても、写し先は写し元と独立している
    source.onConnect = nil
    source.onDisconnect = nil
    source.onDataChannelMessage = nil
    XCTAssertNotNil(copied.onConnect, "写し元の変更が写し先へ影響しないこと")
    XCTAssertNotNil(copied.onDisconnect, "写し元の変更が写し先へ影響しないこと")
    XCTAssertNotNil(copied.onDataChannelMessage, "写し元の変更が写し先へ影響しないこと")
  }

  /// 同じ Configuration から作った 2 接続で handler が交差しないことを確認する
  func testHandlersAreIsolatedBetweenConnectionsFromSameConfiguration() throws {
    let configuration = makeConfiguration()
    let channelA = try MediaChannel(configuration: configuration)
    let channelB = try MediaChannel(configuration: configuration)

    // 接続ごとに configuration のインスタンスをコピーした別インスタンスを持つこと
    XCTAssertFalse(
      channelA.handlers === configuration.mediaChannelHandlers,
      "1 つ目の接続が configuration のインスタンスそのものを持たないこと")
    XCTAssertFalse(
      channelB.handlers === configuration.mediaChannelHandlers,
      "2 つ目の接続が configuration のインスタンスそのものを持たないこと")
    XCTAssertFalse(
      channelA.handlers === channelB.handlers, "接続間で handler のインスタンスを共有しないこと")

    let disconnectA = expectation(description: "1 つ目の接続の切断 handler が呼ばれること")
    let disconnectB = expectation(description: "2 つ目の接続の onDisconnect が呼ばれること")
    disconnectA.assertForOverFulfill = true
    disconnectB.assertForOverFulfill = true
    let callCountA = HandlerCallCounter()

    // 1 つ目の handler は呼び出し回数だけを数える。この時点では 1 つ目の接続を開始しないため、
    // 接続失敗によって呼ばれることはない
    channelA.handlers.onDisconnect = { _ in
      callCountA.increment()
      disconnectA.fulfill()
    }
    // 1 つ目の handler を設定しただけでは 2 つ目のインスタンスに現れないこと。インスタンスを共有する実装では
    // ここで 1 つ目の closure が見えるため、交差を決定的に検出できる (交差の主たる検出はこの断言)
    XCTAssertNil(
      channelB.handlers.onDisconnect, "1 つ目の handler が 2 つ目の接続のインスタンスに現れないこと")

    // 2 つ目の配送は、この接続の onDisconnect で観測する。インスタンスを共有する実装ではこの代入が
    // 1 つ目の handler を上書きするが、その場合は直前の XCTAssertNil が先に失敗する
    channelB.handlers.onDisconnect = { _ in
      disconnectB.fulfill()
    }

    // 2 つ目だけを接続して切断する
    startConnecting(channelB)
    channelB.disconnect(error: nil)
    wait(for: [disconnectB], timeout: Self.timeout)
    XCTAssertEqual(
      callCountA.count, 0, "2 つ目の切断で 1 つ目の接続の handler が呼ばれないこと")

    // 1 つ目の接続を開始して切断すると、1 つ目の handler が 1 回だけ呼ばれる
    startConnecting(channelA)
    channelA.disconnect(error: nil)
    wait(for: [disconnectA], timeout: Self.timeout)
    XCTAssertEqual(callCountA.count, 1, "1 つ目の切断で 1 つ目の handler が 1 回だけ呼ばれること")
    XCTAssertEqual(channelA.state, .disconnected, "1 つ目の接続が切断されること")
  }

  /// 接続の開始前に configuration へ登録した handler が両方の接続で呼ばれることを確認する
  func testHandlersRegisteredBeforeConnectionAreCopiedToEveryConnection() throws {
    let configuration = makeConfiguration()
    let disconnectExpectation = expectation(
      description: "接続の開始前に登録した handler が両方の接続で呼ばれること")
    disconnectExpectation.expectedFulfillmentCount = 2
    disconnectExpectation.assertForOverFulfill = true
    configuration.mediaChannelHandlers.onDisconnect = { _ in
      disconnectExpectation.fulfill()
    }

    // 同じ Configuration から 2 つの接続を作る。接続の開始前に登録した handler は、
    // 接続の開始時にそれぞれの接続へコピーされる。
    let channelA = try MediaChannel(configuration: configuration)
    let channelB = try MediaChannel(configuration: configuration)
    XCTAssertNotNil(channelA.handlers.onDisconnect, "1 つ目の接続に handler がコピーされること")
    XCTAssertNotNil(channelB.handlers.onDisconnect, "2 つ目の接続に handler がコピーされること")

    startConnecting(channelA)
    startConnecting(channelB)
    channelA.disconnect(error: nil)
    channelB.disconnect(error: nil)
    wait(for: [disconnectExpectation], timeout: Self.timeout)
  }

  /// 接続の開始後に MediaChannel.handlers へ設定した handler が次の配送から反映されることを確認する
  func testHandlerSetOnMediaChannelAfterConnectionStartIsDelivered() throws {
    let configuration = makeConfiguration()
    // 接続の開始後に handler property を設定しても、configuration からコピーした handler が
    // 消えないことを確認するため、onConnect を登録しておく
    configuration.mediaChannelHandlers.onConnect = { _ in }

    // 同一 Configuration から 2 つの接続を作る
    let channelA = try MediaChannel(configuration: configuration)
    let channelB = try MediaChannel(configuration: configuration)
    // 2 つ目の接続の配送を待つための handler (後始末の切断、または接続失敗で呼ばれる)
    let disconnectB = expectation(description: "2 つ目の接続の切断 handler が呼ばれること")
    disconnectB.assertForOverFulfill = true
    channelB.handlers.onDisconnect = { _ in
      disconnectB.fulfill()
    }

    startConnecting(channelA)
    startConnecting(channelB)

    let disconnectA = expectation(
      description: "接続の開始後に MediaChannel.handlers へ設定した handler が呼ばれること")
    disconnectA.assertForOverFulfill = true
    // この expectation は接続の開始後に configuration へ設定した handler が呼ばれたときに
    // fulfill され、テストは未 fulfill (タイムアウト) を期待する
    let configurationExpectation = expectation(
      description: "接続の開始後に configuration へ設定した handler が呼ばれたこと")
    // 接続の開始後に MediaChannel.handlers の handler property を設定する
    channelA.handlers.onDisconnect = { _ in
      disconnectA.fulfill()
    }
    configuration.mediaChannelHandlers.onDisconnect = { _ in
      configurationExpectation.fulfill()
    }

    // 接続の開始後の設定で、configuration からコピーした onConnect が消えていないことを確認する。
    // channelA.handlers.onConnect は自分では設定していないため、残っていればコピーされた closure
    XCTAssertNotNil(channelA.handlers.onConnect, "configuration からコピーした handler が残ること")

    channelA.disconnect(error: nil)
    wait(for: [disconnectA], timeout: Self.timeout)
    XCTAssertEqual(
      XCTWaiter.wait(for: [configurationExpectation], timeout: 0), .timedOut,
      "接続の開始後に configuration 側へ設定した handler が接続済みの接続で呼ばれないこと")

    // 2 つ目の接続は後始末のために切断する。接続失敗で既に切断されている場合も待ちは満たされる
    channelB.disconnect(error: nil)
    wait(for: [disconnectB], timeout: Self.timeout)
  }

  /// Sora.connect 経由で作った接続でも configuration のインスタンスがコピーされることを確認する
  func testSoraConnectCopiesConfigurationHandlers() throws {
    let sora = Sora()
    let configuration = makeConfiguration()
    configuration.mediaChannelHandlers.onConnect = { _ in }
    configuration.mediaChannelHandlers.onDisconnect = { _ in }

    let addedExpectation = expectation(description: "接続の開始時に MediaChannel が追加されること")
    let removedExpectation = expectation(
      description: "接続試行のキャンセル後に MediaChannel が除去されること")
    // onAddMediaChannel の中で設定した handler が配送されること (接続ごとの handler 設定の推奨手順)
    let handlerExpectation = expectation(
      description: "onAddMediaChannel で設定した handler が呼ばれること")
    handlerExpectation.assertForOverFulfill = true
    var captured: MediaChannel?
    sora.handlers.onAddMediaChannel = { mediaChannel in
      captured = mediaChannel
      // configuration からコピーされた handler がこの時点で設定済みであること
      XCTAssertNotNil(
        mediaChannel.handlers.onDisconnect,
        "接続の開始前に設定した onDisconnect がコピーされること")
      // 接続ごとの handler 設定の推奨手順。設定した handler の配送は後で確認する
      mediaChannel.handlers.onDisconnect = { _ in
        handlerExpectation.fulfill()
      }
      addedExpectation.fulfill()
    }
    sora.handlers.onRemoveMediaChannel = { _ in
      removedExpectation.fulfill()
    }

    let task = sora.connect(configuration: configuration) { _, _ in }
    wait(for: [addedExpectation], timeout: Self.timeout)
    let mediaChannel = try XCTUnwrap(captured, "接続の開始時に MediaChannel が生成されること")

    XCTAssertFalse(
      mediaChannel.handlers === configuration.mediaChannelHandlers,
      "Sora.connect 経由でも configuration のインスタンスをコピーすること")
    XCTAssertNotNil(
      mediaChannel.handlers.onConnect, "接続の開始前に設定した handler がコピーされること")

    // 接続試行を終端し、handler の配送と MediaChannel の除去通知まで待つ
    task.cancel()
    wait(for: [handlerExpectation, removedExpectation], timeout: Self.timeout)
  }
}
