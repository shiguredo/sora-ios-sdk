import XCTest

@testable import Sora

/// VideoHardMuteActor の lease / revocation 管理に関するユニットテスト
///
/// VideoHardMuteActor.setMute は実カメラ操作を含むため、カメラが利用できない
/// Simulator では mute / unmute の全体 (store / restart / stream 照合) を検証できない。
/// 本テストでは、カメラ操作に到達する前の lease / revocation のロジック
/// (release の冪等性と、storedCapturer との独立) を検証する。
/// カメラが必要な検証 (別接続の capturer 混線など) は実機で確認する。
final class VideoHardMuteActorLeaseTests: XCTestCase {
  // テストで共通利用するシグナリング URL を返す
  private func makeTestURL() -> URL {
    guard let url = URL(string: "wss://example.com") else {
      fatalError("テスト URL の生成に失敗しました")
    }
    return url
  }

  // テスト用の Configuration を構築する
  private func makeConfiguration() -> Configuration {
    let url = makeTestURL()
    return Configuration(
      urlCandidates: [url],
      channelId: "test",
      role: .sendonly)
  }

  // テスト用の MediaChannel / lease / SenderStreamBox / CameraSettingsSnapshot を構築する
  private func makeDependencies() -> (
    mediaChannel: MediaChannel,
    senderStreamBox: SenderStreamBox,
    cameraSettings: CameraSettingsSnapshot
  ) {
    let mediaChannel = MediaChannel(manager: Sora.shared, configuration: makeConfiguration())
    let peerChannel = mediaChannel.peerChannel
    let nativeStream = peerChannel.nativePeerChannelFactory.createNativeStream(streamId: "test")
    let mediaStream = BasicMediaStream(peerChannel: peerChannel, nativeStream: nativeStream)
    return (
      mediaChannel,
      SenderStreamBox(stream: mediaStream),
      CameraSettingsSnapshot(mediaChannel.configuration.cameraSettings)
    )
  }

  /// release は冪等であり、複数回呼んでも安全であることを確認する
  ///
  /// mock / stub は使用しない。release() は「storedCapturer の破棄」と
  /// 「leaseGenerations の世代を進める」のみで、複数回呼んでも状態を壊さない。
  func testReleaseIsIdempotent() async {
    let actor = VideoHardMuteActor()
    let dependencies = makeDependencies()
    let lease = VideoHardMuteLease(channel: ObjectIdentifier(dependencies.mediaChannel))

    // 2 回呼んでもクラッシュせず、安全に完了する
    await actor.release(lease: lease)
    await actor.release(lease: lease)
  }

  /// 未知の lease (release されていない lease) の setMute は revocation で失敗しないことを確認する
  ///
  /// lease ごとに破棄予約 (leaseGenerations) が独立しており、
  /// 別 lease の release がこの lease に影響しないことを検証する。
  func testReleaseOfOtherLeaseDoesNotAffectTarget() async {
    let actor = VideoHardMuteActor()
    let dependencies = makeDependencies()

    // 2 つの異なる MediaChannel を作る (ObjectIdentifier が異なる)
    let mediaChannelA = MediaChannel(manager: Sora.shared, configuration: makeConfiguration())
    let leaseA = VideoHardMuteLease(channel: ObjectIdentifier(mediaChannelA))
    let leaseB = VideoHardMuteLease(channel: ObjectIdentifier(dependencies.mediaChannel))

    // leaseA を release しても leaseB は影響を受けない (カメラ未起動なら冪等 return)
    await actor.release(lease: leaseA)

    do {
      try await actor.setMute(
        mute: true,
        lease: leaseB,
        senderStream: dependencies.senderStreamBox,
        cameraSettings: dependencies.cameraSettings)
      // カメラ未起動のため、冪等として成功 (revocation ではない)
    } catch {
      XCTFail("別 lease の setMute が revocation で失敗することはない: \(error)")
    }
  }
}
