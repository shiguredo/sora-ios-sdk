// このファイルは `#if DEBUG` のテスト用アクセサに依存するため、Debug 構成でのみビルドできます。

import WebRTC
import XCTest

@testable import Sora

/// `createClientOfferSDP` の handler が観測した値と、その handler が accessor から取り出した
/// 一時 `RTCPeerConnection` を、テストスレッドへ排他して受け渡します。
///
/// `@unchecked Sendable` としているのは、可変状態の読み書きをすべて `lock` で排他しており、
/// 非 Sendable な `RTCPeerConnection` を handler の内側からテスト側へ渡すためだけに保持する
/// ためです (handler は WebRTC のスレッドから呼ばれます)。
private final class ClientOfferObservation: @unchecked Sendable {
  private let lock = NSLock()
  private var sdp: String?
  private var error: (any Error)?
  private var callCount = 0
  private var peerConnection: RTCPeerConnection?

  /// handler の引数と、その時点の一時 PC を記録します。
  func record(sdp: String?, error: (any Error)?, peerConnection: RTCPeerConnection?) {
    lock.lock()
    self.sdp = sdp
    self.error = error
    self.peerConnection = peerConnection
    callCount += 1
    lock.unlock()
  }

  var recordedSDP: String? {
    lock.lock()
    defer { lock.unlock() }
    return sdp
  }

  var recordedError: (any Error)? {
    lock.lock()
    defer { lock.unlock() }
    return error
  }

  var recordedCallCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return callCount
  }

  var recordedPeerConnection: RTCPeerConnection? {
    lock.lock()
    defer { lock.unlock() }
    return peerConnection
  }
}

/// `RTCPeerConnectionDelegate` の callback をテストへ中継するだけの観測用 delegate です。
///
/// テストは実 `RTCPeerConnection` と実 `NativePeerChannelFactory` だけを使い、この delegate は
/// WebRTC が呼ぶ callback を中継して `.closed` への遷移を観測するだけです。SDK の振る舞いを
/// 置き換えたり、 production が設定した delegate を差し替えたりしないため、モックやスタブでは
/// ありません。`RTCPeerConnectionDelegate` は `@optional` の前に必須メソッドがあるため、
/// 観測に使わない必須メソッドも空実装します。
/// 観測するのは `RTCPeerConnectionState` の `.closed` への遷移だけです。
private final class ClientOfferCloseObserver: NSObject, RTCPeerConnectionDelegate {
  private let closedExpectation: XCTestExpectation
  private let lock = NSLock()
  private var hasFulfilled = false

  init(closedExpectation: XCTestExpectation) {
    self.closedExpectation = closedExpectation
    super.init()
  }

  // MARK: - RTCPeerConnectionDelegate (必須)

  func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didChange stateChanged: RTCSignalingState
  ) {}

  func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didAdd stream: RTCMediaStream
  ) {}

  func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didRemove stream: RTCMediaStream
  ) {}

  func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

  func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didChange newState: RTCIceConnectionState
  ) {}

  func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didChange newState: RTCIceGatheringState
  ) {}

  func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didGenerate candidate: RTCIceCandidate
  ) {}

  func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didRemove candidates: [RTCIceCandidate]
  ) {}

  func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didOpen dataChannel: RTCDataChannel
  ) {}

  // MARK: - RTCPeerConnectionDelegate (任意)

  func peerConnection(
    _ peerConnection: RTCPeerConnection,
    didChange newState: RTCPeerConnectionState
  ) {
    guard newState == .closed else {
      return
    }
    // libwebrtc から同じ `.closed` が複数回届く場合があるため、fulfill は 1 回に限定します
    // (assertForOverFulfill が有効な expectation を重複で fulfill するとテストが失敗します)。
    lock.lock()
    let shouldFulfill = !hasFulfilled
    hasFulfilled = true
    lock.unlock()
    if shouldFulfill {
      closedExpectation.fulfill()
    }
  }
}

/// 参照保持 box (`@unchecked Sendable`) が担う振る舞いを、実 `RTCPeerConnection` で固定する回帰テストです。
///
/// この file は `createClientOfferSDP` が完了 block の末尾で一時 `RTCPeerConnection` を
/// `close()` する経路を対象にします。box が保持する参照を同じ型のまま別のオブジェクトへ
/// 差し替える変更と、`close()` の呼び出しを削る変更は型検査では検出できないため、
/// 実際に `.closed` へ遷移することを観測して固定します。
/// この file には、残る `getStats` 側の同一性判定のテストも追加する前提です。
/// モックやスタブは使用しません。
final class SendableBoxRegressionTests: XCTestCase {
  /// テストで利用する factory です。
  ///
  /// `RTCPeerConnectionFactory` は `RTCPeerConnection` と track より長生きさせる必要があります
  /// (先に解放すると、transceiver の破棄が破棄済みの task queue を参照してクラッシュします)。
  /// テストメソッドのローカル変数より後に解放されるよう instance で保持し、`tearDown` で解放します。
  private var peerConnectionFactory: NativePeerChannelFactory?

  override func tearDown() {
    peerConnectionFactory = nil
    super.tearDown()
  }

  /// `createClientOfferSDP` が一時 `RTCPeerConnection` を `close()` することを確認する
  ///
  /// 一時 PC はテスト用 accessor から取り出し、handler の内側で delegate を設定します。
  /// handler は box の `close()` より前に呼ばれるため、設定した delegate は `close()` に間に合います。
  func testClientOfferClosesTemporaryPeerConnection() throws {
    let factory = try NativePeerChannelFactory(bypassVoiceProcessing: false)
    peerConnectionFactory = factory

    let webRTCConfiguration = WebRTCConfigurationSnapshot(WebRTCConfiguration())

    let offerExpectation = expectation(description: "クライアント Offer SDP を生成できること")
    let closeExpectation = expectation(description: "一時 RTCPeerConnection が .closed へ遷移すること")
    let observation = ClientOfferObservation()
    // delegate は `RTCPeerConnection` が弱参照するため、テストが強参照で保持します。
    let observer = ClientOfferCloseObserver(closedExpectation: closeExpectation)

    factory.createClientOfferSDP(
      webRTCConfiguration: webRTCConfiguration
    ) { sdp, error in
      // handler の内側では assertion を記録せず、値だけを排他してテスト側へ渡します。
      let peerConnection = factory.lastClientOfferPeerConnectionForTesting
      peerConnection?.delegate = observer
      observation.record(sdp: sdp, error: error, peerConnection: peerConnection)
      offerExpectation.fulfill()
    }

    wait(for: [offerExpectation], timeout: 5)
    XCTAssertEqual(
      observation.recordedCallCount, 1,
      "createClientOfferSDP の handler が 1 回だけ呼ばれること")
    XCTAssertNil(observation.recordedError, "Offer SDP の生成が成功すること")
    XCTAssertNotNil(observation.recordedSDP, "Offer SDP が渡ること")

    guard let tempPeer = observation.recordedPeerConnection else {
      XCTFail("テスト用 accessor から一時 RTCPeerConnection を取得できること")
      return
    }
    // 後始末: テストが失敗しても確実に閉じるようにします。
    defer {
      tempPeer.delegate = nil
      tempPeer.close()
    }

    wait(for: [closeExpectation], timeout: 5)

    XCTAssertEqual(
      tempPeer.connectionState, .closed,
      "一時 RTCPeerConnection が .closed へ遷移すること")
  }
}
