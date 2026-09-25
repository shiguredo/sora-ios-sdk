import XCTest

@testable import Sora

// connect の完了 handler の結果を main queue 経由で受け取るためのボックス
// (生成と読み出しは main queue 上でのみ行う)
private final class ConnectResultBox: @unchecked Sendable {
  var error: Error?
}

// onSwitchVideo の発火値を記録するスレッドセーフなボックス
// (handler は VideoHardMuteActor の executor で呼ばれるため、読み出しと排他する)
private final class VideoSwitchRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [Bool] = []

  func append(_ value: Bool) {
    lock.lock()
    recorded.append(value)
    lock.unlock()
  }

  var values: [Bool] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }
}

// MediaChannel は Sendable ではないため、MainActor 隔離のテストから非分離の async API を
// 呼んだり @Sendable な handler へ参照を渡したりすると送信診断になる。テスト内の利用に
// 限定して参照をこのボックスへまとめる。
//
// このボックスは実行文脈を揃えるものではない。async メソッドは nonisolated のため main actor
// 上では実行されず、handler は SDK 側の任意の実行文脈から呼ばれる。このボックスは可変状態を
// 持たず参照を保持するだけで、安全性は MediaChannel の内部同期に依存する。
private final class ChannelBox: @unchecked Sendable {
  let channel: MediaChannel

  init(_ channel: MediaChannel) {
    self.channel = channel
  }

  var state: ConnectionState { channel.state }
  var senderStream: MediaStream? { channel.senderStream }
  var handlers: MediaChannelHandlers { channel.handlers }

  func connect(
    webRTCConfiguration: WebRTCConfiguration,
    handler: @escaping @Sendable (Error?) -> Void
  ) -> ConnectionTask {
    channel.connect(webRTCConfiguration: webRTCConfiguration, handler: handler)
  }

  func setVideoHardMute(_ mute: Bool) async throws {
    try await channel.setVideoHardMute(mute)
  }

  func disconnect(error: Error?) {
    channel.disconnect(error: error)
  }
}

/// setVideoHardMute(true) の失敗時に senderStream.videoEnabled が黒塗りのまま残らないことを
/// 実 Sora 接続で検証する E2E テスト
///
/// lease を注入するため `Sora.connect` は使わず、`MediaChannel` を直接生成して接続します。
/// 直接生成した `MediaChannel` は `Sora.mediaChannels` に登録されないため、各テストは
/// `addTeardownBlock` で明示的に切断します。
/// 環境変数 SORA_SIGNALING_URL と TEST_SECRET_KEY が未設定の場合はスキップします。
///
/// 設定後の失敗による復元分岐は、起動済みの `CameraVideoCapturer.current` が必要で
/// Simulator では到達できないため、このテストでは検証しません。SwiftPM のテストターゲットは
/// tool-hosted で実機では実行できないため、復元分岐は実機での手動確認とします。
final class VideoHardMuteRollbackE2ETests: E2ETestBase {
  // lease を注入した MediaChannel を実 Sora サーバへ接続して返す
  private func connectChannel(lease: VideoHardMuteLease) async throws -> ChannelBox {
    var config = try buildConfiguration(role: .sendonly)
    config.channelId = buildChannelId(unique: true)
    config.initialCameraEnabled = false
    config.audioEnabled = false
    XCTAssertTrue(config.cameraSettings.isEnabled, "前提: カメラが有効であること")
    XCTAssertTrue(config.videoEnabled, "前提: 映像が有効であること")

    let box = ChannelBox(try MediaChannel(configuration: config, videoHardMuteLease: lease))

    // 接続に失敗した場合も切断するため、connect の前に後始末を登録する
    addTeardownBlock { [box] in
      guard box.state != .disconnected else {
        return
      }
      let disconnected = self.expectation(description: "切断が完了すること")
      box.handlers.onDisconnect = { _ in
        disconnected.fulfill()
      }
      // handler の設定と state の確認の間に切断が完了した場合は、
      // onDisconnect が発火済みで expectation が fulfill されないため消費して戻る
      guard box.state != .disconnected else {
        _ = await self.fulfillment(of: [disconnected], timeout: 0)
        return
      }
      if box.state != .disconnecting {
        box.disconnect(error: nil)
      }
      await self.fulfillment(of: [disconnected], timeout: 10)
    }

    let connected = self.expectation(description: "接続が完了すること")
    let connectResult = ConnectResultBox()
    // connect の完了 handler は SignalingChannel の queue 上で呼ばれるため main へ渡す
    _ = box.connect(webRTCConfiguration: WebRTCConfiguration()) { error in
      DispatchQueue.main.async {
        connectResult.error = error
        connected.fulfill()
      }
    }
    await fulfillment(of: [connected], timeout: 30)
    if let error = connectResult.error {
      throw error
    }
    XCTAssertEqual(box.state, .connected, "接続状態が connected であること")
    XCTAssertNotNil(box.senderStream, "senderStream が存在すること")
    return box
  }

  /// lease を revoke した後の setVideoHardMute(true) が videoEnabled と callback を変えないことを確認する
  ///
  /// この経路は operationTracker.begin による設定前の拒否であり、復元処理は通りません。
  /// 修正前の実装は設定が先に行われるため、このテストが不具合を検出します。
  func testRevokedLeaseDoesNotChangeVideoEnabled() async throws {
    let lease = VideoHardMuteLease()
    let box = try await connectChannel(lease: lease)
    let stream = try XCTUnwrap(box.senderStream)
    XCTAssertTrue(stream.hasVideoTrack, "sender stream が video track を持つこと")
    XCTAssertTrue(stream.videoEnabled, "video track は既定で有効であること")
    let videoSwitches = VideoSwitchRecorder()
    stream.handlers.onSwitchVideo = { videoSwitches.append($0) }

    lease.revoke()

    do {
      try await box.setVideoHardMute(true)
      XCTFail("取消済み lease では失敗すること")
    } catch let error as SoraError {
      guard case .mediaChannelError(let reason) = error else {
        XCTFail("mediaChannelError が返ること: \(error)")
        return
      }
      XCTAssertTrue(
        reason.contains("cancelled"),
        "取消済み lease では cancelled であること: \(reason)")
    }

    XCTAssertTrue(
      stream.videoEnabled,
      "拒否された呼び出しが videoEnabled を変更しないこと")
    XCTAssertTrue(
      videoSwitches.values.isEmpty,
      "拒否された呼び出しが onSwitchVideo を発火しないこと")
  }

  /// カメラ未起動の setVideoHardMute(true) が黒塗りになり、2 回目で追加発火しないことを確認する
  func testNoCameraMuteKeepsVideoEnabledFalse() async throws {
    // 実カメラが current の場合は所有権 guard により復元経路へ入るため、前提を確認する
    guard CameraVideoCapturer.current == nil else {
      throw XCTSkip("実カメラが current のためカメラ未起動の経路を検証できません")
    }

    let lease = VideoHardMuteLease()
    let box = try await connectChannel(lease: lease)
    let stream = try XCTUnwrap(box.senderStream)
    XCTAssertTrue(stream.hasVideoTrack, "sender stream が video track を持つこと")
    XCTAssertTrue(stream.videoEnabled, "video track は既定で有効であること")
    let videoSwitches = VideoSwitchRecorder()
    stream.handlers.onSwitchVideo = { videoSwitches.append($0) }

    // カメラ未起動のため currentCameraVideoCapturer() が nil を返し、冪等成功する
    try await box.setVideoHardMute(true)

    XCTAssertFalse(stream.videoEnabled, "成功時は黒塗りになること")
    XCTAssertEqual(
      videoSwitches.values, [false],
      "成功時は onSwitchVideo(false) が 1 回だけ発火すること")

    // 2 回目は videoEnabled が既に false のため変化せず、callback も追加発火しない
    try await box.setVideoHardMute(true)

    XCTAssertFalse(stream.videoEnabled, "2 回目も黒塗りのままであること")
    XCTAssertEqual(
      videoSwitches.values, [false],
      "2 回目は onSwitchVideo を追加発火しないこと")
  }
}
