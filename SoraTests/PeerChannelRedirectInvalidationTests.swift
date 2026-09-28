import WebRTC
import XCTest

@testable import Sora

/// WebRTC の callback からテストスレッドへ、SDP と呼び出し回数を排他して受け渡す。
///
/// `@unchecked Sendable` としているのは、可変状態が `sdp` と `callCount` だけで、
/// その読み書きをすべて `lock` で排他しているためである
/// (WebRTC の callback は別スレッドから届く)。
private final class PeerChannelSDPResult: @unchecked Sendable {
  private let lock = NSLock()
  private var sdp: String?
  private var callCount = 0

  func record(sdp: String) {
    lock.lock()
    self.sdp = sdp
    callCount += 1
    lock.unlock()
  }

  var recordedSDP: String? {
    lock.lock()
    defer { lock.unlock() }
    return sdp
  }

  var recordedCallCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return callCount
  }
}

/// コールバックの呼び出し回数をテストスレッドへ排他して受け渡す。
///
/// `@unchecked Sendable` としているのは、可変状態が `count` だけで、
/// その読み書きをすべて `lock` で排他しているためである
/// (切断通知は非同期 cleanup の完了後に別スレッドから届く)。
private final class PeerChannelCallCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}

/// redirect 時の旧 transport の論理的な無効化に関するユニットテスト
///
/// production の transport epoch 管理 (dataChannelGeneration / isRedirecting) へ
/// redirect イベントを入力し、旧 DataChannel への送信経路が無効化されることを検証する。
/// モックやスタブは使用しない。
final class PeerChannelRedirectInvalidationTests: XCTestCase {
  /// テストで共通利用する factory です。
  ///
  /// `RTCPeerConnectionFactory` は PeerConnection と track より長生きさせる必要があります
  /// (先に解放すると、transceiver の破棄が破棄済みの task queue を参照してクラッシュします)。
  /// テストメソッドのローカル変数より後に解放されるよう instance で保持し、`tearDown` で解放します。
  private var peerConnectionFactory: NativePeerChannelFactory?

  override func tearDown() {
    peerConnectionFactory = nil
    super.tearDown()
  }

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

  // PeerChannel と接続済みの SignalingChannel を構築する
  private func makePeerChannelWithSignalingChannel(
    config: Configuration
  ) throws -> (peerChannel: PeerChannel, signalingChannel: SignalingChannel) {
    let snapshot = try ConnectionConfigurationSnapshot(configuration: config)
    let signalingChannel = SignalingChannel(
      snapshot: snapshot,
      webSocketChannelHandlers: config.webSocketChannelHandlers)
    let nativeFactory = try NativePeerChannelFactory(bypassVoiceProcessing: false)
    // factory を PeerConnection より長生きさせるため instance でも保持する (tearDown で解放する)
    peerConnectionFactory = nativeFactory
    let peerChannel = PeerChannel(
      snapshot: snapshot,
      signalingChannel: signalingChannel,
      nativePeerChannelFactory: nativeFactory,
      mediaChannel: nil)
    return (peerChannel, signalingChannel)
  }

  /// audio track を追加した実 RTCPeerConnection から有効な offer SDP を生成する
  private func makeOfferSDP(factory: NativePeerChannelFactory) throws -> String {
    let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    guard
      let offerChannel = factory.createNativePeerChannel(
        webRTCConfiguration: WebRTCConfigurationSnapshot(WebRTCConfiguration()),
        delegate: nil)
    else {
      throw SoraError.peerChannelError(
        reason: "failed to create RTCPeerConnection for offer")
    }
    // 一時的な offer 用 PeerConnection は SDP 生成後に閉じる (factory より先に解放する)
    defer { offerChannel.close() }

    // audio track を追加しないと media section の無い offer になり、 answer の m= 行を検証できない
    let track = factory.createNativeAudioTrack(trackId: "audio", constraints: constraints)
    XCTAssertNotNil(
      offerChannel.add(track, streamIds: ["stream"]),
      "offer 用 RTCPeerConnection に audio track を add できること")

    let offerExpectation = expectation(description: "offer SDP を生成できること")
    let offerResult = PeerChannelSDPResult()
    offerChannel.offer(for: constraints) { description, error in
      XCTAssertNil(error, "offer SDP の生成に失敗しないこと")
      if let description {
        offerResult.record(sdp: description.sdp)
      }
      offerExpectation.fulfill()
    }
    wait(for: [offerExpectation], timeout: 10)
    return try XCTUnwrap(offerResult.recordedSDP, "offer SDP が生成されること")
  }

  /// SDP の `m=` 行から media section の種別 (audio / video / application) の並びを取り出す
  ///
  /// libwebrtc が返す SDP の改行は CRLF である。 Swift の `Character` は CRLF を 1 文字として
  /// 扱うため、 `split(separator: "\n")` では改行を 1 つも検出できず、 SDP 全体が 1 行として
  /// 返り `m=` 行を取り出せない (これが原因で `[] == []` の空虚な比較が成立していた)。
  /// 改行種別 (LF / CRLF) に依存しないよう `Character.isNewline` で分割する。
  private func mediaSectionTypes(in sdp: String) -> [String] {
    sdp.split(whereSeparator: { $0.isNewline }).compactMap { line in
      guard line.hasPrefix("m=") else {
        return nil
      }
      guard let firstField = line.split(separator: " ").first else {
        return nil
      }
      return String(firstField.dropFirst(2))
    }
  }

  /// redirect 受理時に `switchedToDataChannel` が false へリセットされ、
  /// `dataChannelGeneration` と `isRedirecting` が更新されることを確認する
  ///
  /// リダイレクト前の状態: switchedToDataChannel = true (DataChannel シグナリングを
  /// 利用した接続済み状態)。リダイレクト受信後は送信経路 (sendMessage / RPC / stats) が
  /// 旧 transport を参照しないよう、switchedToDataChannel を false にする必要がある。
  /// また、旧接続の遅延通知を遮断するため dataChannelGeneration を進め、
  /// 新 offer 受信までの窓では isRedirecting を true にする。
  func testRedirectResetsSwitchedToDataChannelAndGeneration() throws {
    let config = makeConfiguration()
    let (peerChannel, signalingChannel) = try makePeerChannelWithSignalingChannel(config: config)

    // リダイレクト前の接続済み状態を再現する
    // (switchedToDataChannel は DataChannel シグナリング確立時に true になる)
    peerChannel.switchedToDataChannel = true
    let generationBefore = peerChannel.dataChannelGeneration
    XCTAssertFalse(peerChannel.isRedirecting, "リダイレクト前は isRedirecting でないこと")

    // redirect シグナリングを受信する
    signalingChannel.internalHandlers.onReceive?(
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
  func testRedirectPreventsSendMessageToOldDataChannel() throws {
    let config = makeConfiguration()
    // MediaChannel を構築する (内部で自前の SignalingChannel / PeerChannel を持つ)
    // こうすることで MediaChannel.sendMessage が同じ PeerChannel を参照する
    let mediaChannel = try MediaChannel(configuration: config)

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

  /// `.reOffer` 受信時の re-answer 生成経路で、`createAnswer` の handler が 1 回だけ呼ばれ、
  /// `onUpdate` に空でない SDP が渡り、answer の `m=` 行の種別の並びが offer と一致することを確認する
  ///
  /// `createAnswer` は handler を 3 つの非同期 closure と同期経路から参照するため box に包み、
  /// `RTCSessionDescription` と `RTCMediaConstraints` は `Sendable` な値へ写している。
  /// box 化と値の写しで offer / answer の生成結果が変わらないことを、モックを使わずに
  /// 実 `RTCPeerConnection` の offer / answer 経路で固定する。 answer SDP の全文一致は
  /// session id / `a=ice-ufrag` / `a=fingerprint` が実行ごとに変わるため使わない。
  func testReAnswerFromReOfferProducesAnswerMatchingOfferMediaSections() throws {
    let config = makeConfiguration()
    let (peerChannel, signalingChannel) = try makePeerChannelWithSignalingChannel(config: config)

    // PeerChannel に実 RTCPeerConnection を設定する
    let webRTCConfiguration = WebRTCConfigurationSnapshot(WebRTCConfiguration())
    guard
      let nativeChannel = peerChannel.nativePeerChannelFactory.createNativePeerChannel(
        webRTCConfiguration: webRTCConfiguration,
        delegate: peerChannel)
    else {
      XCTFail("PeerChannel 用の RTCPeerConnection を生成できること")
      return
    }
    peerChannel.nativeChannel = nativeChannel
    // 実 RTCPeerConnection もテスト終了時に閉じる (factory より先に解放する)。
    // 先に PeerChannel の参照を外しておき、 close に伴う delegate (.closed) 経由の
    // 切断処理がテスト終了後に走って onDisconnect の expectation を fulfill しないようにする。
    defer {
      peerChannel.nativeChannel = nil
      nativeChannel.close()
    }

    // audio track を追加した実 RTCPeerConnection で有効な offer SDP を作る。
    // media section の無い offer では setRemoteDescription が失敗し、 m= 行の検証も空虚になる。
    let offerSDP = try makeOfferSDP(factory: peerChannel.nativePeerChannelFactory)

    // offer の m= 行が空でないことを固定する (offer に m= が無いまま [] == [] で通る経路を塞ぐ)
    XCTAssertEqual(
      mediaSectionTypes(in: offerSDP), ["audio"],
      "offer の m= 行の種別が audio のみであること")

    // re-answer 成功経路の観測点は onUpdate とする
    // (WebSocket 未接続のため signaling の送信は行われず onSend は呼ばれない)
    let updateExpectation = expectation(description: "re-answer の onUpdate が呼ばれること")
    let observation = PeerChannelSDPResult()
    peerChannel.internalHandlers.onUpdate = { sdp in
      observation.record(sdp: sdp)
      updateExpectation.fulfill()
    }

    // createAnswer の handler が 2 回目にエラー経路で呼ばれると disconnect を経由して
    // onDisconnect が呼ばれる。onUpdate の回数だけでは二重呼び出しを検出できないため、
    // onDisconnect が 1 回も呼ばれないことを固定する。
    let disconnectCounter = PeerChannelCallCounter()
    // 切断通知は非同期 cleanup (カメラ停止) の完了後に届くため、
    // inverted expectation の満了まで待ってから呼び出し回数を検証する。
    let noDisconnectExpectation = expectation(description: "onDisconnect が呼ばれないこと")
    noDisconnectExpectation.isInverted = true
    peerChannel.internalHandlers.onDisconnect = { _, _ in
      disconnectCounter.increment()
      noDisconnectExpectation.fulfill()
    }

    // SignalingChannel から .reOffer として流す
    signalingChannel.internalHandlers.onReceive?(.reOffer(SignalingReOffer(sdp: offerSDP)))

    wait(for: [updateExpectation], timeout: 10)

    XCTAssertEqual(
      observation.recordedCallCount, 1,
      "createAnswer の handler は 1 回だけ呼ばれること (onUpdate の呼び出し回数)")

    let answerSDP = try XCTUnwrap(observation.recordedSDP, "onUpdate に answer の SDP が渡ること")
    XCTAssertFalse(answerSDP.isEmpty, "onUpdate に渡る answer の SDP が空でないこと")
    XCTAssertEqual(
      mediaSectionTypes(in: answerSDP),
      mediaSectionTypes(in: offerSDP),
      "answer の m= 行の種別の並びが offer と一致すること")

    // 二重呼び出しに伴う切断が非同期に通知される場合に備え、
    // inverted expectation の満了まで待ってから onDisconnect が 0 回であることを固定する
    wait(for: [noDisconnectExpectation], timeout: 2)
    XCTAssertEqual(
      disconnectCounter.value, 0,
      "createAnswer の handler の二重呼び出しに伴う切断が起きないこと (onDisconnect の呼び出し回数)")
  }
}
