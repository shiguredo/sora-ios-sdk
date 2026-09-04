import XCTest

@testable import Sora

/// redirect 時の旧 transport の論理的な無効化に関するユニットテスト
///
/// production の transport epoch 管理 (dataChannelGeneration / isRedirecting) へ
/// redirect イベントを入力し、旧 DataChannel への送信経路が無効化されることを検証する。
/// モックやスタブは使用しない。
final class PeerChannelRedirectInvalidationTests: XCTestCase {
  // テストで共通利用するシグナリング URL を返す
  private func makeTestURL() -> URL {
    guard let url = URL(string: "wss://example.com") else {
      fatalError("failed to create test URL")
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

  // PeerChannel と接続済みの SignalingChannel を構築する
  private func makePeerChannelWithSignalingChannel(
    config: Configuration
  ) -> (peerChannel: PeerChannel, signalingChannel: SignalingChannel) {
    let signalingChannel = SignalingChannel(configuration: config)
    let nativeFactory = NativePeerChannelFactory(bypassVoiceProcessing: false)
    let peerChannel = PeerChannel(
      configuration: config,
      signalingChannel: signalingChannel,
      nativePeerChannelFactory: nativeFactory,
      mediaChannel: nil)
    return (peerChannel, signalingChannel)
  }

  /// redirect 受理時に `switchedToDataChannel` が false へリセットされ、
  /// `dataChannelGeneration` と `isRedirecting` が更新されることを確認する
  ///
  /// リダイレクト前の状態: switchedToDataChannel = true (DataChannel シグナリングを
  /// 利用した接続済み状態)。リダイレクト受信後は送信経路 (sendMessage / RPC / stats) が
  /// 旧 transport を参照しないよう、switchedToDataChannel を false にする必要がある。
  /// また、旧接続の遅延通知を遮断するため dataChannelGeneration を進め、
  /// 新 offer 受信までの窓では isRedirecting を true にする。
  func testRedirectResetsSwitchedToDataChannelAndGeneration() {
    let config = makeConfiguration()
    // MediaChannel を構築する (内部で自前の SignalingChannel / PeerChannel / ConnectionStateOwner を持つ)
    let mediaChannel = MediaChannel(manager: Sora.shared, configuration: config)
    let peerChannel = mediaChannel.peerChannel

    // リダイレクト前の接続済み状態を再現する
    // (switchedToDataChannel は DataChannel シグナリング確立時に true になる)
    peerChannel.switchedToDataChannel = true
    // ConnectionStateOwner の phase を接続済み (connected) にする。
    // リダイレクトイベント (.redirectReceived) は connecting / connected からのみ受理される。
    // (実際の接続フローでは基本的に connected である)
    mediaChannel.connectionStateOwner.handle(.connectRequested)
    mediaChannel.connectionStateOwner.handle(.connectionEstablished)

    let generationBefore = peerChannel.dataChannelGeneration
    XCTAssertFalse(peerChannel.isRedirecting, "リダイレクト前は isRedirecting でないこと")

    // redirect シグナリングを受信する
    peerChannel.signalingChannel.internalHandlers.onReceive?(
      .redirect(SignalingRedirect(location: "wss://example2.com/signaling")))

    XCTAssertFalse(
      peerChannel.switchedToDataChannel,
      "リダイレクト後に switchedToDataChannel が false にリセットされること")
    XCTAssertGreaterThan(
      peerChannel.dataChannelGeneration,
      generationBefore,
      "リダイレクト後に dataChannelGeneration が進められること")
    XCTAssertTrue(
      peerChannel.isRedirecting,
      "リダイレクト後 (新 offer 受信までの窓) は isRedirecting が true であること")
  }

  /// redirect 受理時に旧 DataChannel のオンライン状態を保持しないことを確認する
  ///
  /// リダイレクト中に sendMessage が呼ばれた場合、switchedToDataChannel が false のため
  /// 「DataChannel is not open yet」を返す。旧 DataChannel への送信が起きないことを
  /// 実経路 (sendMessage の呼び出し) で検証する。
  func testRedirectPreventsSendMessageToOldDataChannel() {
    let config = makeConfiguration()
    // MediaChannel を構築する (内部で自前の SignalingChannel / PeerChannel を持つ)
    // こうすることで MediaChannel.sendMessage が同じ PeerChannel を参照する
    let mediaChannel = MediaChannel(manager: Sora.shared, configuration: config)

    // リダイレクト前の接続済み状態を再現する
    mediaChannel.peerChannel.switchedToDataChannel = true

    // redirect シグナリングを受信する
    mediaChannel.peerChannel.signalingChannel.internalHandlers.onReceive?(
      .redirect(SignalingRedirect(location: "wss://example2.com/signaling")))

    let error = mediaChannel.sendMessage(label: "#spam", data: Data([0x01]))
    guard let messagingError = error else {
      XCTFail("リダイレクト中の sendMessage はエラーを返すこと")
      return
    }
    guard case SoraError.messagingError(let reason) = messagingError else {
      XCTFail("messagingError が返ること: \(messagingError)")
      return
    }
    XCTAssertTrue(
      reason.contains("not open yet"),
      "旧 DataChannel への送信が拒否されること: \(reason)")
  }
}
