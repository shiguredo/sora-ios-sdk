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

/// `getStats` の handler が返した結果を、WebRTC のスレッドからテスト側へ排他して受け渡します。
///
/// `@unchecked Sendable` としているのは、可変状態 (結果と呼び出し回数) の読み書きをすべて
/// `lock` で排他しており、非 Sendable な `Statistics` を handler の内側からテスト側へ渡すためだけに
/// 保持するためです (handler は WebRTC のスレッドから呼ばれます)。
private final class GetStatsObservation: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<Statistics, any Error>?
  private var callCount = 0

  /// handler の結果と呼び出し回数を記録します。
  func record(_ result: Result<Statistics, any Error>) {
    lock.lock()
    defer { lock.unlock() }
    self.result = result
    callCount += 1
  }

  var recordedResult: Result<Statistics, any Error>? {
    lock.lock()
    defer { lock.unlock() }
    return result
  }

  var recordedCallCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return callCount
  }
}

/// `getStatsWillEvaluateForTesting` / `getStatsSnapshotWillEvaluateForTesting` (`@Sendable`) から
/// 非 Sendable な参照を操作するための箱です。
///
/// テスト用フックの closure は `@Sendable` のため、非 Sendable な `PeerChannel` /
/// `RTCPeerConnection` / `MediaChannel` をそのまま capture できません。実行する操作だけを保持し、
/// テスト用フックの closure にはこの箱だけを capture させます。
///
/// `@unchecked Sendable` としているのは、操作が `PeerChannel.nativeChannel` の差し替え
/// (`transportStorage` の `NSLock` に閉じた代入)、`MediaChannel.setConnectionStateForTesting(_:)`
/// (`connectionLifecycleLock` に閉じた書き込み)、`MediaChannelOwner.release()` (最後の強参照の解放。
/// `MediaChannel.deinit` の本体をこの thread 上で走らせるため、lock に閉じない唯一の例外) の
/// 3 種類で、箱自身は操作の実行以外に状態を読み書きしないためです。
/// この 3 種類の操作だけを渡すことを使用契約とします (別種の操作を渡す場合は根拠を書き換えます)。
/// 同じテストターゲットの他のテストファイルからも使うため internal とします。
final class GetStatsHookAction: @unchecked Sendable {
  private let action: () -> Void

  init(_ action: @escaping () -> Void) {
    self.action = action
  }

  /// テスト用フックから呼ばれる操作を実行します。
  func perform() {
    action()
  }
}

/// `MediaChannel` の唯一の強参照を保持し、`getStats` / `getStatsSnapshot` の完了 block の内側で
/// 解放するための箱です。
///
/// テスト側が `MediaChannel` を直接保持していると、完了 block の内側で最後の参照を解放できません。
/// この箱だけが強参照を持ち、テスト用フックから ``release()`` を呼んで解放します。
/// `@unchecked Sendable` としているのは、強参照の読み書きをすべて `lock` で排他しており、
/// 非 Sendable な `MediaChannel` を解放するためだけに保持するためです (`release()` は
/// WebRTC のスレッドから呼ばれます)。
/// 同じテストターゲットの他のテストファイルからも使うため internal とします。
final class MediaChannelOwner: @unchecked Sendable {
  private let lock = NSLock()
  private var mediaChannel: MediaChannel?

  init(_ mediaChannel: MediaChannel) {
    self.mediaChannel = mediaChannel
  }

  /// 保持している `MediaChannel`。解放済みであれば `nil`。
  var current: MediaChannel? {
    lock.lock()
    defer { lock.unlock() }
    return mediaChannel
  }

  /// 最後の強参照を解放し、`MediaChannel` の解放を開始させます。
  ///
  /// 解放 (`deinit` の一式) は外部コードを呼ぶため、`lock` を解放してから行います。
  func release() {
    lock.lock()
    let released = mediaChannel
    mediaChannel = nil
    lock.unlock()
    withExtendedLifetime(released) {}
  }
}

/// 参照保持 box (`@unchecked Sendable`) が担う振る舞いを、実 `RTCPeerConnection` で固定する回帰テストです。
///
/// このファイルは `createClientOfferSDP` が完了 block の末尾で一時 `RTCPeerConnection` を
/// `close()` する経路と、`getStats` の完了 block の判定の経路、`MediaChannel.state` の読み書きが
/// `MediaChannelStateStorage` 経由であることを対象にします。
/// box が保持する参照を同じ型のまま別のオブジェクトへ差し替える変更と、`close()` の呼び出しを
/// 削る変更は型検査では検出できないため、実際の配送結果を観測して固定します。
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

  /// テスト用の最小の接続設定を作ります。
  private func makeConfiguration() throws -> Configuration {
    let url = try XCTUnwrap(URL(string: "wss://example.com"), "テスト URL を生成できること")
    return Configuration(
      urlCandidates: [url],
      channelId: "test",
      role: .recvonly)
  }

  /// テスト用フックで作った接続状態が `state` と `isAvailable` から同じ値として
  /// 読めることを確認する
  ///
  /// `state` は `MediaChannelStateStorage` を読む computed property、書き込みは `setState(_:)` を
  /// 通るため、このテスト用フックで作った状態が両方の読み出しに反映されることを固定します。
  /// `state` が stored property でなくなったことは公開 API baseline で、正本が `stateStorage`
  /// だけであることは宣言で確認します (テストでは検出できません)。
  /// `isAvailable` を観測するテストは現行の `SoraTests` に他にありません。
  func testConnectionStateForTestingIsObservedThroughStateStorage() throws {
    let mediaChannel = try MediaChannel(configuration: makeConfiguration())

    XCTAssertEqual(mediaChannel.state, .disconnected, "初期状態は .disconnected であること")
    XCTAssertFalse(mediaChannel.isAvailable, "初期状態は isAvailable が false であること")

    mediaChannel.setConnectionStateForTesting(.connecting)
    XCTAssertEqual(
      mediaChannel.state, .connecting,
      "テスト用フックで作った状態が state に反映されること")
    XCTAssertFalse(mediaChannel.isAvailable, ".connecting では isAvailable が false であること")

    mediaChannel.setConnectionStateForTesting(.connected)
    XCTAssertEqual(mediaChannel.state, .connected, ".connected が state に反映されること")
    XCTAssertTrue(
      mediaChannel.isAvailable,
      "state が .connected のとき isAvailable が true であること")

    mediaChannel.setConnectionStateForTesting(.disconnecting)
    XCTAssertEqual(mediaChannel.state, .disconnecting, ".disconnecting が state に反映されること")
    XCTAssertFalse(mediaChannel.isAvailable, ".disconnecting では isAvailable が false であること")

    mediaChannel.setConnectionStateForTesting(.disconnected)
    XCTAssertEqual(
      mediaChannel.state, .disconnected,
      "後始末で .disconnected に戻せること")
    XCTAssertFalse(mediaChannel.isAvailable, ".disconnected では isAvailable が false であること")
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

  /// `getStats` が統計要求時と同じ `RTCPeerConnection` から統計を取得して成功を 1 回返すことを確認する
  ///
  /// `getStats` は `state == .connected` と `peerChannel.nativeChannel != nil` を前提にするため、
  /// テスト用フックで状態を作り、実 `NativePeerChannelFactory` が生成した実
  /// `RTCPeerConnection` を設定します。handler は WebRTC のスレッドから呼ばれるため、handler の
  /// 内側では assertion を記録せず、値だけを排他してテスト側へ渡します。
  func testGetStatsSucceedsWhenPeerConnectionIsUnchanged() throws {
    let mediaChannel = try MediaChannel(configuration: makeConfiguration())
    let peerChannel = mediaChannel.peerChannel
    guard
      let nativeChannel = peerChannel.nativePeerChannelFactory.createNativePeerChannel(
        webRTCConfiguration: WebRTCConfigurationSnapshot(WebRTCConfiguration()),
        delegate: peerChannel)
    else {
      XCTFail("RTCPeerConnection を生成できること")
      return
    }

    // 後始末: テストが失敗しても接続状態と PC を戻します。
    defer {
      peerChannel.nativeChannel = nil
      mediaChannel.setConnectionStateForTesting(.disconnected)
      nativeChannel.close()
    }

    peerChannel.nativeChannel = nativeChannel
    mediaChannel.setConnectionStateForTesting(.connected)

    let statsExpectation = expectation(
      description: "統計要求時と同じ RTCPeerConnection では handler が成功で 1 回呼ばれること")
    let observation = GetStatsObservation()
    mediaChannel.getStats { result in
      // handler は WebRTC のスレッドから呼ばれるため、assertion はテスト側で行います。
      observation.record(result)
      statsExpectation.fulfill()
    }
    wait(for: [statsExpectation], timeout: 5)

    XCTAssertEqual(
      observation.recordedCallCount, 1,
      "getStats の handler が 1 回だけ呼ばれること")
    guard case .success = observation.recordedResult else {
      XCTFail(
        "統計要求時と同じ RTCPeerConnection では成功すること (result: \(String(describing: observation.recordedResult)))"
      )
      return
    }
  }

  /// `getStats` の入口の 2 つの guard が、それぞれの理由で失敗を 1 回返すことを確認する
  ///
  /// この 2 経路は完了 block を経由せず同期で終端するため、`getStats` の完了 block の
  /// テスト用フックを使わずに確定的に確認できます。
  func testGetStatsFailsAtEntryGuards() throws {
    let mediaChannel = try MediaChannel(configuration: makeConfiguration())
    let peerChannel = mediaChannel.peerChannel

    // 接続状態が .connected でない場合は、nativeChannel が nil でも state の guard で終端する。
    let notConnectedExpectation = expectation(
      description: "接続状態が .connected でない場合は handler が失敗で 1 回呼ばれること")
    let notConnectedObservation = GetStatsObservation()
    mediaChannel.getStats { result in
      notConnectedObservation.record(result)
      notConnectedExpectation.fulfill()
    }
    wait(for: [notConnectedExpectation], timeout: 5)

    XCTAssertEqual(
      notConnectedObservation.recordedCallCount, 1,
      "接続状態が .connected でない場合も handler が 1 回だけ呼ばれること")
    guard
      case .failure(let notConnectedError) = notConnectedObservation.recordedResult,
      let notConnectedSoraError = notConnectedError as? SoraError,
      case .peerChannelError(let notConnectedReason) = notConnectedSoraError
    else {
      XCTFail(
        "接続状態が .connected でない場合は失敗すること (result: \(String(describing: notConnectedObservation.recordedResult)))"
      )
      return
    }
    XCTAssertTrue(
      notConnectedReason.contains("MediaChannel is not connected"),
      "接続状態による失敗理由が state を示すこと (reason: \(notConnectedReason))")

    // 接続状態が .connected でも nativeChannel が nil の場合は、nativeChannel の guard で終端する。
    mediaChannel.setConnectionStateForTesting(.connected)
    defer { mediaChannel.setConnectionStateForTesting(.disconnected) }

    XCTAssertNil(peerChannel.nativeChannel, "nativeChannel が未設定であること")
    let unavailableExpectation = expectation(
      description: "nativeChannel が nil の場合は handler が失敗で 1 回呼ばれること")
    let unavailableObservation = GetStatsObservation()
    mediaChannel.getStats { result in
      unavailableObservation.record(result)
      unavailableExpectation.fulfill()
    }
    wait(for: [unavailableExpectation], timeout: 5)

    XCTAssertEqual(
      unavailableObservation.recordedCallCount, 1,
      "nativeChannel が nil の場合も handler が 1 回だけ呼ばれること")
    guard
      case .failure(let unavailableError) = unavailableObservation.recordedResult,
      let unavailableSoraError = unavailableError as? SoraError,
      case .peerChannelError(let unavailableReason) = unavailableSoraError
    else {
      XCTFail(
        "nativeChannel が nil の場合は失敗すること (result: \(String(describing: unavailableObservation.recordedResult)))"
      )
      return
    }
    XCTAssertTrue(
      unavailableReason.contains("RTCPeerConnection is unavailable"),
      "nativeChannel による失敗理由が nativeChannel を示すこと (reason: \(unavailableReason))")
  }

  /// `getStats` の完了 block の内側で `nativeChannel` が差し替わった場合に失敗を 1 回返すことを確認する
  ///
  /// 差し替えは完了 block の判定の先頭で呼ばれる `getStatsWillEvaluateForTesting` で行います。
  /// 実時間の非同期な差し替えではなく、完了 block が評価する時点の状態を確定的に作ります。
  /// 同一性判定 (`currentPeerConnection === context.peerConnection`) を削ると handler が成功を
  /// 返すため、このテストが失敗します。
  func testGetStatsFailsWhenPeerConnectionIsReplacedInCompletionBlock() throws {
    let mediaChannel = try MediaChannel(configuration: makeConfiguration())
    let peerChannel = mediaChannel.peerChannel
    guard
      let requestedChannel = peerChannel.nativePeerChannelFactory.createNativePeerChannel(
        webRTCConfiguration: WebRTCConfigurationSnapshot(WebRTCConfiguration()),
        delegate: peerChannel),
      let replacementChannel = peerChannel.nativePeerChannelFactory.createNativePeerChannel(
        webRTCConfiguration: WebRTCConfigurationSnapshot(WebRTCConfiguration()),
        delegate: peerChannel)
    else {
      XCTFail("RTCPeerConnection を 2 つ生成できること")
      return
    }

    // 統計を要求した時点の PC と、完了 block が評価する時点の PC を別にします。
    let replacement = GetStatsHookAction { peerChannel.nativeChannel = replacementChannel }
    // 後始末: 失敗してもテスト用フック・接続状態・PC を戻します。
    defer {
      mediaChannel.getStatsWillEvaluateForTesting = nil
      peerChannel.nativeChannel = nil
      mediaChannel.setConnectionStateForTesting(.disconnected)
      requestedChannel.close()
      replacementChannel.close()
    }

    peerChannel.nativeChannel = requestedChannel
    mediaChannel.setConnectionStateForTesting(.connected)
    mediaChannel.getStatsWillEvaluateForTesting = { replacement.perform() }

    let statsExpectation = expectation(
      description: "nativeChannel が差し替わった場合は handler が失敗で 1 回呼ばれること")
    let observation = GetStatsObservation()
    mediaChannel.getStats { result in
      // handler は WebRTC のスレッドから呼ばれるため、assertion はテスト側で行います。
      observation.record(result)
      statsExpectation.fulfill()
    }
    wait(for: [statsExpectation], timeout: 5)

    XCTAssertEqual(
      observation.recordedCallCount, 1,
      "getStats の handler が 1 回だけ呼ばれること")
    guard case .failure(let error) = observation.recordedResult,
      let soraError = error as? SoraError,
      case .peerChannelError(let reason) = soraError
    else {
      XCTFail(
        "同一性判定が不一致の場合は SoraError.peerChannelError で失敗すること (result: \(String(describing: observation.recordedResult)))"
      )
      return
    }
    XCTAssertTrue(
      reason.contains("nativeChannel changed"),
      "差し替え後の失敗理由が nativeChannel の変化を示すこと (reason: \(reason))")
  }

  /// `getStats` の完了 block の内側で接続状態が `.disconnected` になった場合に失敗を 1 回返すことを確認する
  ///
  /// 状態の変更は完了 block の判定の先頭で呼ばれる `getStatsWillEvaluateForTesting` で行います。
  /// 完了 block が storage ではなく統計要求時の接続状態を読む変更を入れると、このテストは成功を
  /// 観測して失敗します。
  func testGetStatsFailsWhenConnectionStateChangesInCompletionBlock() throws {
    let mediaChannel = try MediaChannel(configuration: makeConfiguration())
    let peerChannel = mediaChannel.peerChannel
    guard
      let nativeChannel = peerChannel.nativePeerChannelFactory.createNativePeerChannel(
        webRTCConfiguration: WebRTCConfigurationSnapshot(WebRTCConfiguration()),
        delegate: peerChannel)
    else {
      XCTFail("RTCPeerConnection を生成できること")
      return
    }

    // 統計を要求した後に切断された状態を、完了 block が評価する時点で作ります。
    // テスト用フックの closure を `nil` に戻し忘れても `MediaChannel` を延命しないよう
    // 弱参照で捕捉します。
    let disconnect = GetStatsHookAction { [weak mediaChannel] in
      mediaChannel?.setConnectionStateForTesting(.disconnected)
    }
    // 後始末: 失敗してもテスト用フック・接続状態・PC を戻します。
    defer {
      mediaChannel.getStatsWillEvaluateForTesting = nil
      peerChannel.nativeChannel = nil
      mediaChannel.setConnectionStateForTesting(.disconnected)
      nativeChannel.close()
    }

    peerChannel.nativeChannel = nativeChannel
    mediaChannel.setConnectionStateForTesting(.connected)
    mediaChannel.getStatsWillEvaluateForTesting = { disconnect.perform() }

    let statsExpectation = expectation(
      description: "完了 block の評価時に接続状態が変わった場合は handler が失敗で 1 回呼ばれること")
    let observation = GetStatsObservation()
    mediaChannel.getStats { result in
      // handler は WebRTC のスレッドから呼ばれるため、assertion はテスト側で行います。
      observation.record(result)
      statsExpectation.fulfill()
    }
    wait(for: [statsExpectation], timeout: 5)

    XCTAssertEqual(
      observation.recordedCallCount, 1,
      "getStats の handler が 1 回だけ呼ばれること")
    guard case .failure(let error) = observation.recordedResult,
      let soraError = error as? SoraError,
      case .peerChannelError(let reason) = soraError
    else {
      XCTFail(
        "完了 block の評価時に接続状態が変わった場合は失敗すること (result: \(String(describing: observation.recordedResult)))"
      )
      return
    }
    XCTAssertTrue(
      reason.contains("MediaChannel is not connected"),
      "切断後の失敗理由が接続状態を示すこと (reason: \(reason))")
  }

  /// `MediaChannel` の解放開始後に `getStats` の完了 block が走った場合に失敗を 1 回返すことを確認する
  ///
  /// 解放は完了 block の判定の先頭で呼ばれる `getStatsWillEvaluateForTesting` の中で行います。
  /// 解放の確認を削ると完了 block が成功を返すため、このテストが失敗します。`PeerChannel` は
  /// テストが強参照で保持して生存させます (`PeerChannel` も解放されると、終端フラグの確認を削っても
  /// `transportStorage` の nil ガードが同じ失敗を返すため、終端フラグの退行を検出できません)。
  /// `MediaChannel` を保持するのは `MediaChannelOwner` だけで、テスト側は `owner.current` 経由で
  /// 一時的に参照します。
  func testGetStatsFailsWhenMediaChannelIsDeinitializedInCompletionBlock() throws {
    let owner = MediaChannelOwner(try MediaChannel(configuration: makeConfiguration()))
    let peerChannel = try XCTUnwrap(
      owner.current?.peerChannel, "PeerChannel を取得できること")
    guard
      let nativeChannel = peerChannel.nativePeerChannelFactory.createNativePeerChannel(
        webRTCConfiguration: WebRTCConfigurationSnapshot(WebRTCConfiguration()),
        delegate: peerChannel)
    else {
      XCTFail("RTCPeerConnection を生成できること")
      return
    }

    // 後始末: テストが失敗しても PC を戻します (解放経路では deinit が既に閉じています)。
    defer {
      peerChannel.nativeChannel = nil
      owner.current?.setConnectionStateForTesting(.disconnected)
      if nativeChannel.connectionState != .closed {
        nativeChannel.close()
      }
    }

    peerChannel.nativeChannel = nativeChannel
    owner.current?.setConnectionStateForTesting(.connected)
    // 解放が起きない場合に MediaChannel を延命しないよう、箱は弱参照で捕捉します。
    let release = GetStatsHookAction { [weak owner] in owner?.release() }
    owner.current?.getStatsWillEvaluateForTesting = { release.perform() }

    let statsExpectation = expectation(
      description: "解放開始後に完了 block が走った場合は handler が失敗で 1 回呼ばれること")
    let observation = GetStatsObservation()
    owner.current?.getStats { result in
      // handler は WebRTC のスレッドから呼ばれるため、assertion はテスト側で行います。
      observation.record(result)
      statsExpectation.fulfill()
    }
    wait(for: [statsExpectation], timeout: 5)

    XCTAssertEqual(
      observation.recordedCallCount, 1,
      "getStats の handler が 1 回だけ呼ばれること")
    guard case .failure(let error) = observation.recordedResult,
      let soraError = error as? SoraError,
      case .peerChannelError(let reason) = soraError
    else {
      XCTFail(
        "解放開始後に完了 block が走った場合は失敗すること (result: \(String(describing: observation.recordedResult)))"
      )
      return
    }
    XCTAssertEqual(
      reason, "MediaChannel is unavailable",
      "変更前の [weak self] と同じ失敗理由であること (reason: \(reason))")
  }

  /// 解放と接続状態の変更が同じ完了 block の内側で起きた場合に、解放の確認が優先されることを確認する
  ///
  /// 解放の確認が `state == .connected` の確認より前にあることを、失敗理由で固定します
  /// (`.disconnected` へ遷移させてから解放するため、順序が逆だと `MediaChannel is not connected`
  /// が返ります)。解放の手順と前提は `testGetStatsFailsWhenMediaChannelIsDeinitializedInCompletionBlock`
  /// と同じです。
  func testGetStatsReportsUnavailableWhenStateChangesBeforeDeinitialization() throws {
    let owner = MediaChannelOwner(try MediaChannel(configuration: makeConfiguration()))
    let peerChannel = try XCTUnwrap(
      owner.current?.peerChannel, "PeerChannel を取得できること")
    guard
      let nativeChannel = peerChannel.nativePeerChannelFactory.createNativePeerChannel(
        webRTCConfiguration: WebRTCConfigurationSnapshot(WebRTCConfiguration()),
        delegate: peerChannel)
    else {
      XCTFail("RTCPeerConnection を生成できること")
      return
    }

    // 後始末: テストが失敗しても PC を戻します (解放経路では deinit が既に閉じています)。
    defer {
      peerChannel.nativeChannel = nil
      owner.current?.setConnectionStateForTesting(.disconnected)
      if nativeChannel.connectionState != .closed {
        nativeChannel.close()
      }
    }

    peerChannel.nativeChannel = nativeChannel
    owner.current?.setConnectionStateForTesting(.connected)
    // テスト用フックの内側では、先に接続状態を `.disconnected` にしてから最後の強参照を
    // 解放します (フックが戻る前に解放が起きるため、次に進む前に `MediaChannel` はいません)。
    let releaseAndDisconnect = GetStatsHookAction { [weak owner] in
      owner?.current?.setConnectionStateForTesting(.disconnected)
      owner?.release()
    }
    owner.current?.getStatsWillEvaluateForTesting = { releaseAndDisconnect.perform() }

    let statsExpectation = expectation(
      description: "接続状態の変更後に解放された場合は handler が失敗で 1 回呼ばれること")
    let observation = GetStatsObservation()
    owner.current?.getStats { result in
      // handler は WebRTC のスレッドから呼ばれるため、assertion はテスト側で行います。
      observation.record(result)
      statsExpectation.fulfill()
    }
    wait(for: [statsExpectation], timeout: 5)

    XCTAssertEqual(
      observation.recordedCallCount, 1,
      "getStats の handler が 1 回だけ呼ばれること")
    guard case .failure(let error) = observation.recordedResult,
      let soraError = error as? SoraError,
      case .peerChannelError(let reason) = soraError
    else {
      XCTFail(
        "接続状態の変更後に解放された場合は失敗すること (result: \(String(describing: observation.recordedResult)))"
      )
      return
    }
    XCTAssertEqual(
      reason, "MediaChannel is unavailable",
      "解放の確認が state の確認より前に行われること (reason: \(reason))")
  }
}
