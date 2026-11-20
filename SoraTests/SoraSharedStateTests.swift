// このファイルは `#if DEBUG` のテスト用アクセサに依存するため、Debug 構成でのみビルドできます。

import XCTest

@testable import Sora

/// `Sora` の生成と接続の登録が、process-wide な owner を汚さずに解除されることを確認します。
///
/// テストごとに新しい `SoraLifecycleOwner` を作り、`Sora(lifecycleOwner:)` または
/// `MediaChannel` の `lifecycleRegistration` へ注入します。接続先には到達できない `.invalid`
/// ドメインを使い、設定エラー・キャンセル・切断で終端します。
final class SoraSharedStateTests: XCTestCase {
  // 接続先に使う到達不能な URL。
  // `.invalid` は名前解決が必ず失敗する予約済みの TLD であり、誤って外部へ接続しない。
  // テスト用の固定 URL であり、失敗しない。
  // swiftlint:disable:next force_unwrapping
  private static let unreachableURL = URL(string: "wss://sora.invalid/signaling")!

  /// テスト用の `Configuration` を作ります。
  private static func makeConfiguration() -> Configuration {
    var configuration = Configuration(
      urlCandidates: [unreachableURL],
      channelId: "sora-shared-state",
      role: .recvonly)
    configuration.audioEnabled = false
    return configuration
  }

  /// `Sora` の生成が lifecycle owner に登録され、生成の完了で解除されること。
  func testSoraInitializationDoesNotLeaveRegistration() {
    let owner = SoraLifecycleOwner()
    let sora = Sora(lifecycleOwner: owner)

    // 生成中の登録は生成の完了で解除される。生成中の状態は観測できないため、最終的な登録数だけを確認する。
    XCTAssertEqual(owner.registrationCount, 0)
    withExtendedLifetime(sora) {}
  }

  /// 設定エラーで終端した接続の登録が解除され、登録数が 0 に戻ること。
  func testConnectConfigurationErrorReleasesRegistration() {
    let owner = SoraLifecycleOwner()
    let sora = Sora(lifecycleOwner: owner)

    var configuration = Self.makeConfiguration()
    // JSON 化できない dataChannels は接続開始前に設定エラーとして終端する。
    configuration.dataChannels = Data([0x01])

    let finished = expectation(description: "設定エラーで接続が終端すること")
    _ = sora.connect(configuration: configuration) { _, error in
      XCTAssertNotNil(error, "設定エラーが handler へ渡ること")
      finished.fulfill()
    }

    // 設定エラー経路で同期的に登録が解除される。
    XCTAssertEqual(owner.registrationCount, 0)
    wait(for: [finished], timeout: 10)
  }

  /// 登録を渡した `MediaChannel` は、保持している間だけ登録数に数えられ、解放で解除されること。
  func testMediaChannelDeinitReleasesRegistration() throws {
    let owner = SoraLifecycleOwner()
    let configuration = Self.makeConfiguration()
    let snapshot = try ConnectionConfigurationSnapshot(configuration: configuration)

    var registration: SoraLifecycleRegistration?
    switch owner.beginRegistration() {
    case .registered(let value):
      registration = value
    case .finished:
      return XCTFail("終了状態ではないため登録できること")
    }

    var mediaChannel: MediaChannel? = try MediaChannel(
      snapshot: snapshot,
      configuration: configuration,
      audioDevice: nil,
      mediaChannelHandlers: configuration.mediaChannelHandlers,
      webSocketChannelHandlers: configuration.webSocketChannelHandlers,
      lifecycleRegistration: registration)
    // テスト側の参照を手放し、MediaChannel だけが登録トークンを保持する状態にする。
    registration = nil
    XCTAssertNotNil(mediaChannel, "MediaChannel を生成できること")
    XCTAssertEqual(owner.registrationCount, 1, "接続の登録が 1 件数えられること")

    mediaChannel = nil
    XCTAssertEqual(owner.registrationCount, 0, "MediaChannel の解放で登録が解除されること")
  }

  /// 切断が完了した接続の登録が解除されること。
  func testDisconnectReleasesRegistration() throws {
    let owner = SoraLifecycleOwner()
    let configuration = Self.makeConfiguration()
    let snapshot = try ConnectionConfigurationSnapshot(configuration: configuration)

    var registration: SoraLifecycleRegistration?
    switch owner.beginRegistration() {
    case .registered(let value):
      registration = value
    case .finished:
      return XCTFail("終了状態ではないため登録できること")
    }

    var mediaChannel: MediaChannel? = try MediaChannel(
      snapshot: snapshot,
      configuration: configuration,
      audioDevice: nil,
      mediaChannelHandlers: configuration.mediaChannelHandlers,
      webSocketChannelHandlers: configuration.webSocketChannelHandlers,
      lifecycleRegistration: registration)
    registration = nil
    XCTAssertNotNil(mediaChannel)
    XCTAssertEqual(owner.registrationCount, 1)

    let disconnected = expectation(description: "切断が完了すること")
    mediaChannel?.handlers.onDisconnect = { _ in disconnected.fulfill() }
    _ = mediaChannel?.connect(webRTCConfiguration: WebRTCConfiguration()) { _ in }
    XCTAssertEqual(mediaChannel?.state, .connecting, "接続の開始直後の状態が .connecting であること")
    mediaChannel?.disconnect(error: nil)
    wait(for: [disconnected], timeout: 10)

    XCTAssertEqual(owner.registrationCount, 0, "切断の完了で登録が解除されること")
    XCTAssertEqual(mediaChannel?.state, .disconnected, "接続が切断されること")
    mediaChannel = nil
  }

  /// `ConnectionTask.cancel()` で終端した接続の登録が解除され、管理対象から除去されること。
  func testConnectCancellationReleasesRegistration() {
    let owner = SoraLifecycleOwner()
    let sora = Sora(lifecycleOwner: owner)
    let configuration = Self.makeConfiguration()

    let finished = expectation(description: "キャンセルで接続が終端すること")
    let removed = expectation(description: "接続が管理対象から除去されること")
    // Sora.remove は内部 handler で接続 handler より後に呼ばれるため、Sora の onDisconnect で待つ。
    sora.handlers.onDisconnect = { _, _ in removed.fulfill() }
    let task = sora.connect(configuration: configuration) { _, error in
      XCTAssertNotNil(error, "キャンセルが handler へ渡ること")
      finished.fulfill()
    }
    task.cancel()
    wait(for: [finished, removed], timeout: 10)

    XCTAssertEqual(owner.registrationCount, 0, "キャンセルで登録が解除されること")
    XCTAssertTrue(sora.mediaChannels.isEmpty, "キャンセルした接続が管理対象から除去されること")
  }
}
