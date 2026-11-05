import WebRTC
import XCTest

@testable import Sora

/// `Sora.connect` の `webRTCConfiguration` 引数が接続に使う設定へ反映されることのテスト
///
/// `webRTCConfiguration` 引数は長らく無視され、接続には `Configuration.webRTCConfiguration`
/// だけが使われていた。本テストは次の 5 点を、接続開始時に生成される snapshot、
/// `PeerChannel` の接続所有設定、`MediaChannel.configuration` で検証する。
///
/// - 引数を指定した接続では、引数の WebRTC 設定が使われる
/// - 引数を省略した接続では、`Configuration.webRTCConfiguration` が使われる (既存利用者の非退行)
/// - 引数と `Configuration.webRTCConfiguration` の両方を指定した場合は、引数が使われる
/// - 引数を指定した場合は、`Configuration.webRTCConfiguration` のフィールドが残らない (全体置換)
/// - 引数を指定した接続でも、`MediaChannel.configuration` は渡した `Configuration` を返す
///
/// モックやスタブは使わず、実際の `Sora` / `MediaChannel` / `PeerChannel` を生成して設定を読む。
/// 接続先には到達できない `.invalid` ドメインを使い、接続試行をキャンセルするため、
/// テストはサーバーを必要としない。
final class SoraConnectWebRTCConfigurationTests: XCTestCase {
  /// 接続先に使う到達不能な URL
  ///
  /// `.invalid` は名前解決が必ず失敗する予約済みの TLD であり、誤って外部へ接続しない。
  private static let unreachableURL = URL(string: "wss://sora.invalid/signaling")!

  /// 待機に使う上限 (秒)
  ///
  /// キャンセル後の除去通知も通常はすぐ届くため、この値は失敗時に待つ上限を与えるだけで、
  /// 負荷の高い環境でも偽陽性を出さないよう余裕を持たせる。
  private static let notificationTimeout: TimeInterval = 5

  /// テスト用の `Configuration` を構築する
  private func makeConfiguration() -> Configuration {
    Configuration(
      urlCandidates: [Self.unreachableURL],
      channelId: "test",
      role: .sendonly)
  }

  /// 区別できる WebRTC 設定を構築する
  ///
  /// 引数の設定と `Configuration.webRTCConfiguration` の設定を、ICE サーバー・ICE トランスポート
  /// ポリシー・メディア制約・劣化設定のすべてで区別できる値にする。ICE サーバーは 2 個設定し、
  /// snapshot がリスト全体を写し取ることも確認できるようにする。
  ///
  /// - parameter label: ICE サーバーの URL とメディア制約に埋め込む識別子
  /// - parameter iceTransportPolicy: ICE 通信ポリシー
  /// - parameter degradationPreference: 送信する映像の品質が維持できない場合の挙動
  /// - parameter isTLSInsecure: TURN-TLS の検証をスキップするかどうか
  private func makeWebRTCConfiguration(
    label: String,
    iceTransportPolicy: ICETransportPolicy,
    degradationPreference: DegradationPreference?,
    isTLSInsecure: Bool = false
  ) -> WebRTCConfiguration {
    var configuration = WebRTCConfiguration()
    let turnServer = ICEServerInfo(
      urls: ["turn:\(label).example.com:3478?transport=udp"],
      userName: "\(label)-user",
      credential: "\(label)-credential")
    // TURN-TLS の検証設定も snapshot へ写し取られることを確認するため、テストから真値を設定する。
    turnServer.isTLSInsecure = isTLSInsecure
    let stunServer = ICEServerInfo(
      urls: ["stun:\(label).example.com:3478"],
      userName: nil,
      credential: nil)
    configuration.iceServerInfos = [turnServer, stunServer]
    configuration.iceTransportPolicy = iceTransportPolicy
    configuration.constraints.mandatory = ["test-mandatory": label]
    configuration.constraints.optional = ["test-optional": label]
    configuration.degradationPreference = degradationPreference
    return configuration
  }

  /// `Sora.connect` の `webRTCConfiguration` 引数を省略して接続し、生成された `MediaChannel` を返す
  ///
  /// 引数の既定値 (`nil`) を使う既存利用者と同じ呼び出し方で、`Sora.connect` へ
  /// `webRTCConfiguration` を渡さない。
  ///
  /// - parameter sora: 接続に使う `Sora`
  /// - parameter configuration: クライアントの設定
  /// - returns: 接続開始時に生成された `MediaChannel`
  private func connectAndCapture(
    sora: Sora,
    configuration: Configuration
  ) throws -> MediaChannel {
    try connectAndCapture(sora: sora) { handler in
      sora.connect(configuration: configuration, handler: handler)
    }
  }

  /// `Sora.connect` に `WebRTCConfiguration` を指定して接続し、生成された `MediaChannel` を返す
  ///
  /// 既存利用者と同じ形で非 optional の `WebRTCConfiguration` を渡す。optional の引数位置への
  /// 暗黙の昇格でコンパイルできることの確認を兼ねる。
  ///
  /// - parameter sora: 接続に使う `Sora`
  /// - parameter configuration: クライアントの設定
  /// - parameter webRTCConfiguration: `Sora.connect` へ渡す WebRTC 設定
  /// - returns: 接続開始時に生成された `MediaChannel`
  private func connectAndCapture(
    sora: Sora,
    configuration: Configuration,
    webRTCConfiguration: WebRTCConfiguration
  ) throws -> MediaChannel {
    try connectAndCapture(sora: sora) { handler in
      sora.connect(
        configuration: configuration,
        webRTCConfiguration: webRTCConfiguration,
        handler: handler)
    }
  }

  /// `Sora.connect` を呼び出して接続開始時に生成された `MediaChannel` を返す
  ///
  /// `onAddMediaChannel` は `MediaChannel.connect` の `onPrepared` から同期的に呼ばれるため、
  /// `connect` の呼び出しが戻った時点で `MediaChannel` を受け取れている。接続試行を
  /// `ConnectionTask.cancel()` で終端し、`onRemoveMediaChannel` の通知まで待って後始末する。
  ///
  /// - parameter connect: 引数の handler を `Sora.connect` へ渡して `ConnectionTask` を返す closure
  /// - returns: 接続開始時に生成された `MediaChannel`
  private func connectAndCapture(
    sora: Sora,
    connect: (@escaping (MediaChannel?, Error?) -> Void) -> ConnectionTask
  ) throws -> MediaChannel {
    let addedExpectation = expectation(description: "接続開始時に MediaChannel が追加されること")
    let removedExpectation = expectation(description: "接続試行のキャンセル後に MediaChannel が除去されること")
    var addedCount = 0
    var removedCount = 0
    var captured: MediaChannel?
    sora.handlers.onAddMediaChannel = { mediaChannel in
      addedCount += 1
      XCTAssertEqual(addedCount, 1, "MediaChannel は 1 回だけ追加されること")
      // expectation の over-fulfill (API violation) を避けるため、fulfill は 1 回目だけにする。
      guard addedCount == 1 else {
        return
      }
      captured = mediaChannel
      addedExpectation.fulfill()
    }
    sora.handlers.onRemoveMediaChannel = { _ in
      removedCount += 1
      XCTAssertEqual(removedCount, 1, "MediaChannel は 1 回だけ除去されること")
      guard removedCount == 1 else {
        return
      }
      removedExpectation.fulfill()
    }

    let task = connect { _, _ in }
    wait(for: [addedExpectation], timeout: Self.notificationTimeout)

    // 接続試行を終端し、キャンセル経由の除去通知まで待つ。実際のサーバーへは接続しない。
    task.cancel()
    wait(for: [removedExpectation], timeout: Self.notificationTimeout)
    return try XCTUnwrap(captured, "接続開始時に MediaChannel が生成されること")
  }

  /// `PeerChannel` が保持する WebRTC 設定が期待する `WebRTCConfiguration` と一致することを検証する
  ///
  /// 利用者由来の snapshot と接続所有の設定の両方を比較する。接続所有の設定は offer の生成と
  /// `RTCPeerConnection` の生成で使われるため、snapshot から接続所有値への写し取りの退行も
  /// 検出できる。
  private func assertPeerChannelWebRTCConfiguration(
    _ peerChannel: PeerChannel,
    equals expected: WebRTCConfiguration,
    message: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    assertWebRTCConfiguration(
      peerChannel.snapshot.webRTCConfiguration,
      equals: expected,
      message: "\(message): 利用者由来 snapshot",
      file: file, line: line)
    assertWebRTCConfiguration(
      peerChannel.currentWebRTCConfiguration(),
      equals: expected,
      message: "\(message): 接続所有の設定",
      file: file, line: line)
  }

  /// snapshot の WebRTC 設定が期待する `WebRTCConfiguration` と一致することを検証する
  ///
  /// ICE サーバー・ICE トランスポートポリシー・メディア制約・劣化設定を比較する。
  /// `SDPSemantics` は現在 1 ケースのみで、`isInsecure` は `WebRTCConfiguration` のフィールドでは
  /// ないため比較しない。
  private func assertWebRTCConfiguration(
    _ actual: WebRTCConfigurationSnapshot,
    equals expected: WebRTCConfiguration,
    message: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(
      actual.iceServerInfos.map(\.urls), expected.iceServerInfos.map(\.urls),
      "\(message): ICE サーバーの URL", file: file, line: line)
    XCTAssertEqual(
      actual.iceServerInfos.map(\.username), expected.iceServerInfos.map(\.userName),
      "\(message): ICE サーバーのユーザー名", file: file, line: line)
    XCTAssertEqual(
      actual.iceServerInfos.map(\.credential), expected.iceServerInfos.map(\.credential),
      "\(message): ICE サーバーのクレデンシャル", file: file, line: line)
    XCTAssertEqual(
      actual.iceServerInfos.map(\.isTLSInsecure), expected.iceServerInfos.map(\.isTLSInsecure),
      "\(message): ICE サーバーの TURN-TLS 検証設定", file: file, line: line)
    XCTAssertEqual(
      actual.iceTransportPolicy, expected.iceTransportPolicy,
      "\(message): ICE 通信ポリシー", file: file, line: line)
    XCTAssertEqual(
      actual.constraints.mandatory, expected.constraints.mandatory,
      "\(message): 必須のメディア制約", file: file, line: line)
    XCTAssertEqual(
      actual.constraints.optional, expected.constraints.optional,
      "\(message): オプションのメディア制約", file: file, line: line)
    XCTAssertEqual(
      actual.degradationPreference, expected.degradationPreference,
      "\(message): 劣化設定", file: file, line: line)
  }

  /// 引数を指定したとき、引数の WebRTC 設定が使われることを確認する
  ///
  /// `Configuration.webRTCConfiguration` は既定値のままにして、引数だけで設定を変えられることを
  /// 検証する。修正前は引数が完全に無視されていたため、このテストは修正の再発防止になる。
  func testWebRTCConfigurationArgumentIsReflected() throws {
    let sora = Sora()
    var configuration = makeConfiguration()
    // webRTCConfiguration 以外の Configuration の設定が snapshot に保持されることも確認する。
    configuration.insecure = true
    let argument = makeWebRTCConfiguration(
      label: "argument",
      iceTransportPolicy: .all,
      degradationPreference: .maintainResolution,
      isTLSInsecure: true)

    let mediaChannel = try connectAndCapture(
      sora: sora,
      configuration: configuration,
      webRTCConfiguration: argument)

    assertPeerChannelWebRTCConfiguration(
      mediaChannel.peerChannel,
      equals: argument,
      message: "webRTCConfiguration 引数を指定した接続")
    XCTAssertTrue(
      mediaChannel.peerChannel.snapshot.insecure,
      "Configuration.insecure が snapshot に保持されること")
  }

  /// 引数を省略したとき、`Configuration.webRTCConfiguration` が使われることを確認する
  ///
  /// 引数の既定値は `nil` であり、`nil` のときは従来どおり `Configuration.webRTCConfiguration` を
  /// 使う。既存利用者と同じく `webRTCConfiguration` 引数を渡さない呼び出しがそのままコンパイル
  /// でき、従来の設定が使われることを検証する。
  func testOmittedWebRTCConfigurationUsesConfigurationValue() throws {
    let sora = Sora()
    var configuration = makeConfiguration()
    let expected = makeWebRTCConfiguration(
      label: "configuration",
      iceTransportPolicy: .all,
      degradationPreference: .balanced)
    configuration.webRTCConfiguration = expected

    let mediaChannel = try connectAndCapture(
      sora: sora,
      configuration: configuration)

    assertPeerChannelWebRTCConfiguration(
      mediaChannel.peerChannel,
      equals: expected,
      message: "webRTCConfiguration 引数を省略した接続")
  }

  /// 引数と `Configuration.webRTCConfiguration` の両方を指定したとき、引数が使われることを確認する
  ///
  /// 2 つの設定を ICE サーバー・ICE 通信ポリシー・劣化設定のすべてで異なる値にし、snapshot と
  /// 接続所有の設定が `Configuration.webRTCConfiguration` ではなく引数の値になることを検証する。
  func testWebRTCConfigurationArgumentWinsOverConfigurationValue() throws {
    let sora = Sora()
    var configuration = makeConfiguration()
    let configurationWebRTCConfiguration = makeWebRTCConfiguration(
      label: "configuration",
      iceTransportPolicy: .relay,
      degradationPreference: .maintainFramerate)
    configuration.webRTCConfiguration = configurationWebRTCConfiguration
    let argument = makeWebRTCConfiguration(
      label: "argument",
      iceTransportPolicy: .all,
      degradationPreference: .disabled)

    let mediaChannel = try connectAndCapture(
      sora: sora,
      configuration: configuration,
      webRTCConfiguration: argument)

    assertPeerChannelWebRTCConfiguration(
      mediaChannel.peerChannel,
      equals: argument,
      message: "webRTCConfiguration 引数と Configuration の両方を指定した接続")
    // `MediaChannel.configuration` は引数を反映せず、利用者が渡した `Configuration` の値を
    // 返し続ける (公開互換)。この分離が退行しないことを確認する。
    assertWebRTCConfiguration(
      WebRTCConfigurationSnapshot(mediaChannel.configuration.webRTCConfiguration),
      equals: configurationWebRTCConfiguration,
      message: "MediaChannel.configuration")
  }

  /// 引数を指定したとき、`Configuration.webRTCConfiguration` のフィールドが残らないことを確認する
  ///
  /// 引数の `WebRTCConfiguration` は全体が置き換わる。引数側が空・既定値でも、Configuration 側の
  /// ICE サーバー・ICE トランスポートポリシー・メディア制約・劣化設定は残らないことを検証する。
  func testWebRTCConfigurationArgumentReplacesConfigurationValue() throws {
    let sora = Sora()
    var configuration = makeConfiguration()
    configuration.webRTCConfiguration = makeWebRTCConfiguration(
      label: "configuration",
      iceTransportPolicy: .all,
      degradationPreference: .balanced,
      isTLSInsecure: true)
    let argument = WebRTCConfiguration()

    let mediaChannel = try connectAndCapture(
      sora: sora,
      configuration: configuration,
      webRTCConfiguration: argument)

    assertPeerChannelWebRTCConfiguration(
      mediaChannel.peerChannel,
      equals: argument,
      message: "webRTCConfiguration 引数で全体置換した接続")
  }
}
