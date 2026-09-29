# 参照保持 box の同一性判定と `close()` の回帰テストを追加する

- Created: 2026-09-28
- Completed: {YYYY-MM-DD}
- Priority: Low
- Branch: feature/add-sendable-box-regression-tests
- Polished: 2026-09-28

## 目的

`0173` が `Sora/MediaChannel.swift` の `getStats` と `Sora/NativePeerChannelFactory.swift` の `createClientOfferSDP` に追加した参照保持 box (`@unchecked Sendable`) が担っている 2 つの振る舞いを、回帰テストで固定する。

- `MediaChannel.getStats` の完了 block 内の `currentPeerConnection === context.peerConnection` の同一性判定
- `NativePeerChannelFactory.createClientOfferSDP` の完了 block の内側での `context.peerConnection.close()`

この 2 つは型検査では守れない。box が保持する `RTCPeerConnection` の型を変えずに別のオブジェクトを渡す変更も、`close()` の呼び出しを削る変更も、型は変わらないため診断が出ない。`0173` はこの 2 経路にテストを追加せず、型検査と `SoraTests` 全体を回帰の正本とした (「`MediaChannel.getStats` は `state` を `.connected` にする経路が private のため単体 harness を作らない」)。型検査で守れない部分だけをテストで補うのが本 issue である。

## 優先度根拠

利用者に見える挙動と公開 API を変えないテストの追加であり、実装済みの変更に対する補強であるため Low とする。ただし `0173` の 2 経路は、同じ型のまま同一性判定を削る変更も `close()` の呼び出しを削る変更も型検査と既存テストでは落ちない。`getStats` 側は `0177` が同じ closure を触るため `0177` の設計が確定するまで着手しないとしてきたが、`0177` は 2026-09-29 に完了した。`0177` が別 issue (`0178`) へ分離した `MediaChannel.state` の単一所有化は本 issue の前提ではなく、本 issue は `0177` が確立した `setState(_:)` の経路に合わせて着手できる (「部分完了の記録」)。

## 現状

### 部分完了の記録

`createClientOfferSDP` 側 (`Sora/NativePeerChannelFactory.swift` の `#if DEBUG` アクセサと `SoraTests/SendableBoxRegressionTests.swift` の `close()` の回帰テスト) は実装・検証済みである。

`getStats` 側 (`Sora/MediaChannel.swift` の同一性判定と `#if DEBUG` の seam、`setConnectionStateForTesting(_:)`) は `0177` (2026-09-29 完了) の完了により着手できる。`0177` は `getStats` の完了 closure から `self` の読みを消し、次の形にした。

- closure は `MediaChannelGetStatsContext` (`@unchecked Sendable`) だけを捕捉し、state は `context.stateStorage` (`MediaChannelStateStorage` の `NSLock`)、`nativeChannel` の同一性判定は `context.transportStorage` (`PeerChannelTransportStorage` の `NSLock`、弱参照) 経由で読む
- `MediaChannel.state` は公開 API の表現 (ABI dump の `HasStorage` / `HasInitialValue` と getter の `Transparent`) を変えられないため stored property のまま維持し、`connectionLifecycleLock` 配下で `state` と `stateStorage` を同時に更新する遷移ヘルパー (`setState(_:)`) を追加した。computed property へ移すと `make api-check-fresh` の fresh な dump が committed baseline と一致しないため、`0177` の設計方針の「差分が出た場合は storage 化を別 issue に分離し、本 issue では `state` の読みを別の排他に閉じる方式へ切り替える」に従った。分離先は `0178` (open、`MediaChannel.state` の単一所有への整理) である。`state` に `didSet` を付けて `stateStorage` の写しを追随させる方式も、暗黙の getter から `Transparent` が外れて baseline と一致しなくなるため採らない
- したがって `setConnectionStateForTesting(_:)` は `connectionLifecycleLock` 配下で `state` を直接代入せず、`0177` の遷移ヘルパー (`setState(_:)`) と同じ経路を通して `stateStorage` も更新する。`state` だけを代入すると `getStats` の完了 closure が読む `stateStorage` の写しが古くなり、テストが観測する同一性判定の分岐へ到達しない。`0178` が `state` を computed property 化した後は、このアクセサも `0178` の書き込み経路に合わせる
- seam は `0177` 後の実装に合わせ、`getStats` が box へ渡す不変の値として持たせ、closure は `context` 経由で呼ぶ (`self` の読みを再導入しない)

`MediaChannel.state` を単一の lock 付き storage へ移す整理 (ABI 変更と baseline の再生成、上記の seam の追随を伴う) は `0177` が `0178` へ分離した。本 issue はその整理を待たず、`0177` が確立した `setState(_:)` の経路に合わせて `getStats` 側の同一性判定を観測する。

`getStats` 側を実装した時点で `CHANGES.md` の同一エントリを『同一性判定と `close()`』へ更新する。

### 対象の 2 箇所

`Sora/MediaChannel.swift` の `MediaChannel.getStats` は、handler と統計取得対象の `RTCPeerConnection` を不変の参照保持 box `MediaChannelGetStatsContext` へ移し、`peerConnection.statistics` の完了 block で統計要求時のオブジェクトと現在の `peerChannel.nativeChannel` の同一性を判定する。

```swift
private final class MediaChannelGetStatsContext: @unchecked Sendable {
  let handler: (Result<Statistics, any Error>) -> Void
  let peerConnection: RTCPeerConnection
```

```swift
    let context = MediaChannelGetStatsContext(
      handler: handler,
      peerConnection: peerConnection)
    peerConnection.statistics { [weak self] report in
      ...
      guard let currentPeerConnection = self.peerChannel.nativeChannel,
        currentPeerConnection === context.peerConnection
      else {
        let message =
          "RTCPeerConnection is unavailable (state: \(self.state), nativeChannel changed)"
```

`peerChannel.nativeChannel` を差し替えるのは `Sora/PeerChannel.swift` の `PeerChannel.createAndSendAnswer(offer:)` であり、新しい offer を受信するたびに `nativeChannel = nativePeerChannelFactory.createNativePeerChannel(...)` で新しい `RTCPeerConnection` に置き換わる。同一性判定は、統計要求後にこの差し替えが起きた場合に旧オブジェクトの統計を成功として返さないためのものである。

`Sora/NativePeerChannelFactory.swift` の `createClientOfferSDP` は、局所名 `tempPeer` の一時 `RTCPeerConnection` と handler を `ClientOfferSDPCreationContext` へ移し、`tempPeer.offer(for:)` の完了 block の最後で一時 PC を閉じる。

```swift
  private final class ClientOfferSDPCreationContext: @unchecked Sendable {
    let handler: (String?, (any Error)?) -> Void
    let peerConnection: RTCPeerConnection
```

```swift
    let context = ClientOfferSDPCreationContext(handler: handler, peerConnection: tempPeer)
    tempPeer.offer(for: webRTCConfiguration.nativeConstraints) { sdp, error in
      if let error {
        context.handler(nil, error)
      } else if let sdp {
        context.handler(sdp.sdp, nil)
      } else {
        context.handler(nil, SoraError.peerChannelError(reason: "offer creation failed"))
      }
      context.peerConnection.close()
    }
```

### 現在のテストの観測点

`SoraTests/StereoAudioOutputTests.swift` の `testClientOfferKeepsStereoPlayoutForNextPeerConnection` は、`createClientOfferSDP` の handler で `error` が `nil` で `sdp` が非 `nil` であることだけを確認する。`wait` の後は `createNativePeerChannel` で作った別の PC を `close()` し、`factory.audioDeviceModule` が `nil` にならないことを確認する。

```swift
    factory.createClientOfferSDP(
      webRTCConfiguration: webRTCConfiguration
    ) { sdp, error in
      XCTAssertNil(error)
      XCTAssertNotNil(sdp)
      offerExpectation.fulfill()
    }
    wait(for: [offerExpectation], timeout: 5)

    // 同じ signaling thread で後続 PC を生成するため、Offer callback と一時 PC の close 完了後に進む。
    // 続けて PC を入れ替え、redirect のように実接続が一時的に存在しない場合も確認する。
    for _ in 0..<2 {
      let peer = try XCTUnwrap(
        factory.createNativePeerChannel(
          webRTCConfiguration: webRTCConfiguration,
          delegate: nil))
      XCTAssertNotNil(
        factory.audioDeviceModule,
        "PeerConnection の作り直し後も ADM を保持すること")
      peer.close()
    }
```

このテストが観測するのは Offer SDP の生成と ADM の保持であり、`createClientOfferSDP` が作った一時 PC への参照はテストへ渡らない。コメントは「一時 PC の close 完了後に進む」と close を前提にしているが、close が呼ばれたことは確認していない。

- `testFactoryCreatesActualADMForStereoPlayout` と `testFactoryCreatesActualADMWithoutStereoPlayout` は `RTCAudioDeviceModule` の生成だけを観測する。stereo playout と AudioSession の各テスト (`testStereoCategoryFollowsSenderRole` / `testMediaChannelDeinitClosesNativePeerConnectionAndReleasesRequirement` など) は `AudioSessionCoordinator` の要求数を観測し、`testMediaChannelDeinitClosesNativePeerConnectionAndReleasesRequirement` は `nativeChannel.connectionState` も観測する。いずれも box は観測しない。
- `getStats` を呼ぶテストは実 Sora へ接続する E2E (`SendonlyE2ETests` / `SendrecvE2ETests` / `SimulcastE2ETests` / `RpcE2ETests` / `MessagingE2ETests` / `StereoAudioOutputE2ETests`) だけであり、`Statistics` の内容を確認する。同一性判定と `nativeChannel` の差し替えは確認していない。
- 実 `RTCPeerConnection` の close の観測前例は `SoraTests/StereoAudioOutputTests.swift` の `testMediaChannelDeinitClosesNativePeerConnectionAndReleasesRequirement` にある。`peerChannel.nativeChannel = nativeChannel` で実 PC を設定し、`MediaChannel` の解放後に `XCTAssertEqual(nativeChannel.connectionState, .closed)` で確認している。
- 実 `RTCPeerConnection` の `close()` で `RTCPeerConnectionDelegate` の `.closed` 通知が届くことは、同じ file の `testNativePeerConnectionCloseReleasesRequirement` が `nativeChannel.close()` の後に `internalHandlers.onDisconnect` を `XCTestExpectation` で待って観測している。`SoraTests/PeerChannelRedirectInvalidationTests.swift` も「`close` に伴う delegate (`.closed`) 経由の切断処理」を前提に `defer` で後始末の順序を調整している。

### `getStats` の単体 harness が無い理由

- `Sora/MediaChannel.swift` の `state` は `public private(set) var state: ConnectionState = .disconnected` であり、`.connected` を代入する経路は `private func finishConnect(connectionTask:)` の 1 箇所だけである。`finishConnect` は `MediaChannel.basicConnect(connectionTask:)` の `peerChannel.connect` 完了 handler から呼ばれ、実際のシグナリング接続の成功を前提にする。
- `getStats` は先頭で `guard state == .connected` を満たさない場合に handler へ failure を返して return するため、`.connected` へ到達できない単体テストでは box の判定まで進まない。
- `SoraTests/StereoAudioOutputTests.swift` の `testConnectFinishesAfterSoraIsReleased` は到達不能な URL (`wss://127.0.0.1:1`) で接続失敗を期待しており、実ネットワークなしに `.connected` へ到達する経路は無い。
- `0164` の調査のとおり redirect は `connect` への応答としてのみ届き、WebRTC 接続確立後にサーバーから送られることはない。したがって実 Sora へ接続する E2E でも、`.connected` 中に `nativeChannel` が別の `RTCPeerConnection` へ差し替わる状況は作れない。

### テスト用アクセサの前例

- `Sora/ConnectionTimer.swift` の `currentGeneration` は、doc コメントに「テストから現在の生成世代を確認するための内部アクセサ。(実運用では使用しない。generation の管理と検証のために公開する)」と書かれた read-only の internal アクセサで、テストから世代の検証に使う。
- `Sora/MediaChannel.swift` の `isConnectionTimerRunning` は「接続タイマーの終端状態を回帰テストから確認するための内部アクセサーです。」と doc コメントを持つ read-only の internal アクセサである。
- `Sora/ScreenCapture.swift` の `setMediaChannelConnectionRequiredForTesting(_:)` は「接続を行わずに送信経路を駆動するテストと、接続状態の確認が frame を破棄することを確認するテストのために internal とする。本番では常に `true` のままで、この setter は呼びません。」と doc コメントを持つテスト専用 setter である。
- `Sora/StreamFrameOwner.swift` の `processedSequencesForTesting` は、上限の無い観測用の配列 (stored property) と accessor を `#if DEBUG` で囲み、production に観測用の状態を持ち込まない形の前例である。`SoraTests/StreamFrameOwnerTests.swift` がこの accessor を参照して成功しているため、`SoraTests` を build する構成では `DEBUG` が定義される。
- `Package.swift` は `swift-tools-version:5.3` で、`Sora` / `SoraTests` に `swiftSettings` を持たず `DEBUG` を明示的に定義していない。`DEBUG` は Xcode の Debug 構成 (`SWIFT_ACTIVE_COMPILATION_CONDITIONS`) で定義される。`SoraTests` は `.github/workflows/e2e-test.yml` の `xcodebuild build-for-testing` (構成指定なし) で build されるため `#if DEBUG` のアクセサを参照でき、`make build` と `make consumer-build` / `make api-check-fresh` (いずれも Release) では存在しない。したがって `#if DEBUG` のアクセサは Release の挙動と公開 API baseline に現れない。
- 到達しない経路や本番で発生しない状態を確定的に駆動するために production へテスト可能な seam を置く判断は、`0127` (open) が「epoch 照合と pong 送信の境界は単体テストで検証できるよう production のテスト可能な経路として実装し」と書いており、前例がある。逆に `0175` (完了 2026-09-28) は「この 1 経路のテストのために production コードへテスト専用の API を追加しない」と決めており、その理由は対象経路が所有関係上到達不能で、テストで再現するには production の契約を変える必要があるためである。本 issue の `getStats` と `createClientOfferSDP` はどちらも到達可能で、テストから観測する手段だけが無い点で `0175` と事情が異なる。

## 前提となる issue

- `0173` (完了 2026-09-28): box の追加元。`## スコープ外` と `## 解決方法` が「`MediaChannel.getStats` は `state` を `.connected` にする経路が private のため単体 harness を作らない」と記録しており、本 issue はこの判断の穴を埋める。
- `0177` (2026-09-29 完了): `#SendableClosureCaptures` の 10 件を解消し、`MediaChannel.getStats(handler:)` の `RTCPeerConnection.statistics` 完了 closure は `MediaChannelGetStatsContext` だけを捕捉する形になった。`context` は state storage (`MediaChannelStateStorage`) と `PeerChannel` の transport storage (`PeerChannelTransportStorage`、弱参照) を保持し、`currentPeerConnection === context.peerConnection` の同一性判定の意味は変えていない。本 issue が追加するテストを正本とし、`0177` は同一経路のテストを追加していない。`getStats` 側のテストと `#if DEBUG` の seam (「設計方針」) は `0177` 後の実装へ向けて設計し、seam が `self` の読みを再導入しない形 (`getStats` が box へ渡す不変の値として持たせる) にする。`0177` は `MediaChannel.state` を computed property 化せず stored property のまま維持したため、`.connected` を作る `setConnectionStateForTesting(_:)` は `0177` の遷移ヘルパー (`setState(_:)`) と同じ経路で `stateStorage` も更新すること (「部分完了の記録」)。`MediaChannel.state` の単一所有化は `0178` が扱う。`createClientOfferSDP` 側は `0177` の対象ではないため、`0177` を待たずに実施できる。
- `0164` (open): redirect が接続確立前にのみ届くことの調査。本 issue が内部アクセサを使う根拠である。
- `0118` (完了 2026-09-25) と `0171` (open): `SoraTests` は Swift 6 言語モードで build され、`0171` の完了後は warnings-as-errors になる。追加するテストは concurrency 診断を出さない書き方にする。

## 設計方針

モックやスタブは使わず、実 `RTCPeerConnection` と実 `MediaChannel` / 実 `NativePeerChannelFactory` だけで観測する。

### 一時 PC の `close()` の観測

- `Sora/NativePeerChannelFactory.swift` に、`createClientOfferSDP` が作った一時 PC をテストから参照するための internal な `weak` アクセサ (例: `lastClientOfferPeerConnectionForTesting`) を追加し、`createClientOfferSDP` の `guard let tempPeer` の直後に代入する。代入と宣言はどちらも同じ `#if DEBUG` で囲む (Release では宣言が無いため、代入だけを残すと build できない)。`weak` にするのは、production の参照寿命と Release の挙動を変えないためである (前例 `StreamFrameOwner.processedSequencesForTesting`)。このアクセサは直近の 1 個だけを保持するため、テストは `createClientOfferSDP` を 1 回だけ呼び、他の呼び出しと重ならないようにする。
- テストは `createClientOfferSDP` の handler の内側でアクセサから一時 PC を取り出してテスト側で強参照し、同じ handler の内側で `RTCPeerConnectionDelegate` を設定する。handler は `close()` より前に呼ばれるため、delegate の設定は `close()` に間に合う。`RTCPeerConnection.delegate` は `weak` なので、delegate はテストクラス自身 (XCTest がテスト中は保持する) にするか、テストが保持する property に置く。
- delegate の型は `NSObject` に準拠させ、`RTCPeerConnectionDelegate` の**必須メソッド 9 個** (Swift 名で `peerConnection(_:didChange:)` ×3 (`RTCSignalingState` / `RTCIceConnectionState` / `RTCIceGatheringState`)、`peerConnection(_:didAdd:)`、`peerConnection(_:didRemove:)` ×2 (`RTCMediaStream` / `[RTCIceCandidate]`)、`peerConnectionShouldNegotiate(_:)`、`peerConnection(_:didGenerate:)`、`peerConnection(_:didOpen:)`) を空実装する必要がある (WebRTC のヘッダで `@optional` の前にあるため)。観測に使う `peerConnection(_:didChange newState: RTCPeerConnectionState)` は `@optional` (ObjC selector は `peerConnection:didChangeConnectionState:`) で、`.closed` のときだけ `XCTestExpectation` を fulfill する。この delegate は WebRTC の callback をテストへ中継する観測用の実装であり、SDK の振る舞いを差し替えるモックやスタブではない。空実装を避けたい場合は、実 `PeerChannel` を delegate にして `peerChannel.nativeChannel` へ一時 PC を設定し、`.closed` による `internalHandlers.onDisconnect` を待つ方法もある (`PeerChannel.peerConnection(_:didChange:)` は `isCurrentPeerConnection` の判定を通る必要があるため、`nativeChannel` の設定が要る)。
- `close()` が削られた場合も、box が `tempPeer` 以外のオブジェクトを保持して実際の一時 PC が閉じられない場合も、`.closed` へ遷移せず timeout するため失敗する。
- 実 `RTCPeerConnection` の `close()` で `.closed` の delegate 通知が届くことは `testNativePeerConnectionCloseReleasesRequirement` で観測済みである (「現状」)。届かない場合に限り、`connectionState` を 10 ms 間隔・上限 5 秒で確認する条件待ちに置き換える (実 `RTCPeerConnection` の `connectionState` が `.closed` になることは `testMediaChannelDeinitClosesNativePeerConnectionAndReleasesRequirement` で観測済みである)。
- 観測用 delegate を使わない代替案として、`connectionState == .closed` になるまで条件待ちする方式がある。この方式にすれば delegate の必須メソッド 9 個の空実装と観測用の型をテストへ置かずに済む。現行は delegate の `.closed` 通知で `close()` の完了そのものを観測する方式を採っており、この代替案は条件待ちの間隔と上限に依存する点を許容できる場合の判断材料として残す。

### `getStats` の同一性判定の観測

- `Sora/MediaChannel.swift` にテスト用の internal アクセサ (例: `setConnectionStateForTesting(_:)`) を追加し、実接続を伴わずに `.connected` を作る。`connectionLifecycleLock` 配下で設定し、`#if DEBUG` で囲み、production では呼ばないことを日本語コメントで書く。名前と粒度は `ScreenCapture.setMediaChannelConnectionRequiredForTesting(_:)` に揃える。このアクセサは `finishConnect` を通らずに `state` だけを変えるため、テストは `getStats` 以外の接続ライフサイクル API を呼ばず、後始末で `setConnectionStateForTesting(.disconnected)` に戻してから `MediaChannel` を解放する。
- 実 `NativePeerChannelFactory` で `RTCPeerConnection` を 2 つ (`pcA` / `pcB`) 作り、`peerChannel.nativeChannel` で差し替える。`MediaChannel.peerChannel` と `PeerChannel.nativeChannel` は internal であり、`SoraTests/StereoAudioOutputTests.swift` と `SoraTests/PeerChannelRedirectInvalidationTests.swift` が既に同じ設定方法を使っている。
- 成功側: `state` を `.connected` にし、`peerChannel.nativeChannel = pcA` で `getStats` を呼び、handler が success で 1 回だけ呼ばれることを `XCTestExpectation` で固定する。box が `pcA` 以外のオブジェクトを保持する変更が入ると同一性判定が不一致になり handler が failure を返すため、このテストが落ちる。
- 不一致側: 差し替えが `statistics` の完了 block の内側で確定するよう、`getStats` の完了 block が同一性判定の直前で呼ぶ `#if DEBUG` の internal な seam (例: `getStatsWillEvaluateForTesting`) を追加し、呼び出しも `#if DEBUG` で囲む。テストはこの seam で `peerChannel.nativeChannel` を `pcB` へ差し替え、handler が failure で 1 回だけ呼ばれることを固定する。同一性判定が削除または `!= nil` の確認へ書き換わると handler が success を返すため、このテストが落ちる。`state` は `.connected` のままなので、失敗は同一性判定の分岐 (`nativeChannel changed`) だけから返る。この seam が再現するのは、`PeerChannel.createAndSendAnswer(offer:)` による `nativeChannel` の置き換え (redirect 相当) が statistics の完了より前に起きた場合に、完了 block が評価する状態そのものである。実時間の非同期な差し替えではなく、評価時点の状態を確定的に作る。
- この seam は `#if DEBUG` で囲み、`0177` が `getStats` の完了 closure から `self` の読みを消した後も `self` の読みを再導入しない形にする (`getStats` が box へ渡す不変の値として持たせ、closure は `context` 経由で呼ぶ)。テスト側の closure は `@Sendable` にし、非 Sendable な `PeerChannel` / `RTCPeerConnection` は `@unchecked Sendable` のテスト用 box に包んでから渡す (前例 `SoraTests/PeerChannelRedirectInvalidationTests.swift` の `PeerChannelSDPResult` / `PeerChannelCallCounter`)。
- box が旧 `RTCPeerConnection` の参照を保持していること自体は、弱参照の生存では観測しない。統計の完了前は box 以外の参照の有無で結果が変わり得るため、観測点は handler が返す結果にする。box が統計要求時のオブジェクトを参照し続けていることは、成功側 (box が `pcA` を保持) と不一致側 (差し替え後は一致しない) の両方で固定する。
- `DispatchSemaphore` で実 `RTCPeerConnection` の `statistics` 完了 block を停止させ、停止中に `getStats` を呼んで `nativeChannel` を差し替える案は採らない。`Sora/SignalingChannel.swift` の `owner` のコメントと `Sora/SignalingState.swift` の `enqueue` の doc に「`PeerChannel` 経由で呼ぶ `RTCPeerConnection` の API が libwebrtc の signaling thread の完了を待つ」と書かれている。`statistics` が signaling thread の完了を待つ API である場合、完了 block を signaling thread 上で停止させたまま `getStats` (内部で `peerConnection.statistics`) を呼ぶと呼び出し元が停止し、`DispatchSemaphore` の timeout では救えない。待たない場合、完了 block が signaling thread 以外で呼ばれるなら停止が後続の完了を直列化しない。`statistics` がどちらであるかはコードから確認できず、どちらの場合も「差し替えが完了 block より前に確定すること」を保証できないため、順序をスレッドのタイミングに依存させない上記の seam を使う。実 `RTCPeerConnection` の完了順で順序を保証する案 (先行する `statistics` の完了 block で差し替える等) も、完了 block の実行順が呼び出し順と一致する保証がコード上に無いため採らない。

### internal アクセサの是非

- 採用する。`getStats` の box の判定は `.connected` を前提にし、`.connected` へは private な `finishConnect` からしか到達できない。`0164` のとおり redirect は接続確立前に届くため E2E でも `.connected` 中の差し替えを作れず、実接続を使わずに判定へ到達する手段が他に無い。
- 追加するのは「観測のための internal なアクセサと seam」だけで、Release の production の経路・分岐・配送は変えない (Debug では seam の呼び出しと `weak` アクセサへの代入が 1 つずつ増える)。すべて `#if DEBUG` で囲むため Release には存在せず、internal のため公開 API baseline にも現れない (「テスト用アクセサの前例」)。`weak` アクセサは stored property を 1 つ増やすが、`#if DEBUG` のため Release の instance レイアウトは変わらない。
- `0175` は「この 1 経路のテストのために production コードへテスト専用の API を追加しない」と決めているが、対象経路が所有関係上到達不能で、テストで再現するには production の契約自体を変える必要があるためである。本 issue の 2 経路はどちらも到達可能で、テストから観測する手段 (一時 PC の参照、`.connected` の作成、差し替えの順序) だけが無い。`0127` も同じ理由で「production のテスト可能な経路として実装し」と決めており、本 issue の判断はこれに沿う。
- 反対意見への回答: `state` を直接代入するアクセサは接続ライフサイクルの契約を迂回する。`connectionLifecycleLock` 配下に限定し、`#if DEBUG` で囲んで Release に代入経路を残さず、テストは後始末で `setConnectionStateForTesting(.disconnected)` に戻してから `MediaChannel` を解放する。`state` だけを変えても `currentConnectionTask` / `connectionTimerAuthorization` / `hasStartedConnection` は変わらないため、テストは `getStats` 以外の接続ライフサイクル API を呼ばない。production の経路は変更しない。
- 採らない案: `MediaChannelGetStatsContext` を internal にして同一性判定だけを単体で呼ぶ案は、box に渡すオブジェクトをテスト自身が決めるため「`getStats` が正しいオブジェクトを box へ渡しているか」を検出できない。E2E だけで観測する案は `.connected` 中の差し替えを作れず、不一致側を検出できない。`DispatchSemaphore` で完了 block を止める案は「`getStats` の同一性判定の観測」に書いた理由で順序を保証できない。

### その他

- public API のシグネチャと利用者に見える挙動を変えない。追加するアクセサは internal または `#if DEBUG` であり、公開 API baseline に現れない。
- 追加するテストとアクセサのコメントに issue 番号を書かない。ソースコードには理由そのものを書く。

## スコープ外

- `0177` が扱う `MediaChannel.getStats(handler:)` の `self` 捕捉の解消と、`Sora` target に残る他の 9 件の `#SendableClosureCaptures`。本 issue は box の判定の回帰テストだけを扱う。
- `0108` の Sora target warnings-as-errors ゲートと `0171` の test target warnings-as-errors ゲートの導入、および警告の解消。
- `PeerChannel.handleSignalingOverWebSocket(_:)` の `case .ping` にある統計 pong の送信経路。同じ `nativeChannel` の差し替えを見るが、box ではなく `isCurrentPeerConnection` を使う別の経路であり、`0127` が扱う。
- `MediaChannel.getStats` の `#SendableClosureCaptures` を解消するための実装の書き換え (0177 の担当) と、box の doc コメントの変更。本 issue はテストとテスト用の観測用アクセサおよび seam の追加に限り、`getStats` の判定ロジックと配送は変えない。
- `0173` が追加した他の box (`Sora/PeerChannel.swift` の `CreateAnswerHandlerBox` / `Sora/CameraVideoCapturer.swift` の `CameraOperationCompletionBox` / `Sora/ConnectionTimer.swift` の `ConnectionTimerHandlerBox`) の回帰テスト。本 issue は同一性判定と `close()` を持つ 2 経路に限る。`createAnswer` の handler 呼び出し契約は `0175` が扱う。

## 変更対象

- `Sora/NativePeerChannelFactory.swift`: 一時 PC を参照するテスト用の internal アクセサ (例: `lastClientOfferPeerConnectionForTesting`) の追加と、`createClientOfferSDP` での代入
- `Sora/MediaChannel.swift`: `.connected` を作るテスト用の internal アクセサ (例: `setConnectionStateForTesting(_:)`) と、`statistics` の完了 block が同一性判定の直前に呼ぶ `#if DEBUG` の seam (例: `getStatsWillEvaluateForTesting`) の追加
- `SoraTests/`: 参照保持 box の回帰テストを追加する (新規 `SoraTests/SendableBoxRegressionTests.swift` を想定)
  - `createClientOfferSDP` の一時 PC が `.closed` へ遷移すること (delegate の `.closed` または `connectionState` で確認)
  - `getStats` が同一の `RTCPeerConnection` のままなら success を返し、seam での差し替え後は failure を返すこと
  - `NativePeerChannelFactory` と `MediaChannel` を `tearDown` で解放し、テストが作った `RTCPeerConnection` を `close()` する後始末
- 実施順: `createClientOfferSDP` 側 (0177 の対象外) を先に完了させ、`getStats` 側は `0177` の完了後に `0177` 後の実装へ向けて行う。`Sora/MediaChannel.swift` の seam は `0177` の変更と競合しない形で追加する
- `CHANGES.md`: `## develop` の `### misc` に `[ADD]` で「参照保持 box の同一性判定と `close()` の回帰テストを追加する」を追記し、`#if DEBUG` のテスト用アクセサと seam を含むこと、公開 API と Release の利用者の挙動の変更がないことを補足行に書く (担当者行 `- @t-miya` を含める)

## テスト方針

モックやスタブは使用しない。

- 実ネットワークへ接続しない。`Sora.connect` と `SignalingChannel` を使わず、`MediaChannel` と `NativePeerChannelFactory` を直接作り、実 `RTCPeerConnection` の `connectionState` と `statistics` だけを使う。
- WebRTC の callback は別スレッドから届くため、handler の内側では assertion を記録せず、可変状態は lock で排他するか main queue へ hop してから検証する。前例は `SoraTests/PeerChannelRedirectInvalidationTests.swift` の `PeerChannelSDPResult` と `SoraTests/SendonlyE2ETests.swift` の `getStats` handler である。新しいテストクラスは `@MainActor` にしない (`SoraTests/StereoAudioOutputTests.swift` と同じ)。`getStats` の handler は `@Sendable` ではないため、`@MainActor` のテストから渡すと MainActor 隔離を継承して WebRTC スレッドからの呼び出しが実行時違反になる。handler には `{ @Sendable result in ... }` の形で `@Sendable` を明示し、非 `Sendable` な `MediaChannel` / `RTCPeerConnection` / `Statistics` は handler の内側へ持ち込まず、Sendable な値へ写してから main queue へ渡す (`SendonlyE2ETests.waitForStats` と同じ方式)。
- `XCTestExpectation` は「handler が呼ばれたこと」と「`.closed` への遷移」の両方で使い、`wait` の後に handler の引数と回数を検証する。成功側と不一致側は別の expectation で待ち、`handler` が 1 回だけ呼ばれることも確認する。
- 後始末: `peerChannel.nativeChannel` の PC とテストが保持する PC を `close()` する。`RTCPeerConnectionFactory` は `RTCPeerConnection` と track より長生きさせる必要があるため、`NativePeerChannelFactory` を instance で保持し `tearDown` で解放する (前例 `SoraTests/PeerChannelRedirectInvalidationTests.swift` の `peerConnectionFactory`)。`MediaChannel` 側は `setConnectionStateForTesting(.disconnected)` に戻し、seam の closure を `nil` に戻してから解放する。
- 退行検出の確認: 追加したテストが現行の実装で成功し、`createClientOfferSDP` の `context.peerConnection.close()` を削った作業ツリーと、`getStats` の `currentPeerConnection === context.peerConnection` を削った作業ツリーのそれぞれで失敗することを確認する。確認用の変更は commit しない。
- 追加したテストを単独で 10 回以上実行し、flaky でないことを確認する。E2E は実行しない (実 Sora を必要とするため)。
- `SoraTests` 全体を実行して失敗 0 件であること。`make fmt-lint` と `make lint` が成功すること。`make api-check-fresh` が成功し、`git diff --exit-code -- TestConsumers/Swift6Consumer/ApiBaseline/` が空であること。
- 追加したテストが Swift 6 言語モードで concurrency 診断を出さないこと (`SoraTests` を build する `.github/workflows/e2e-test.yml` の invocation で確認する)。

## 完了条件

- `createClientOfferSDP` の一時 PC の `close()` を削ると失敗し、現行の実装で成功するテストがあること。観測は delegate の `.closed` (または `connectionState`) で行い、`close()` を呼ばない実装でその通知が来ないことを確認していること。
- `getStats` の同一性判定を削除または書き換えると失敗し、現行の実装で成功するテストがあること。同一の `RTCPeerConnection` のままなら success、seam で `nativeChannel` を差し替えた後は failure を返すことの両方が固定されていること。
- 差し替えが `statistics` の完了 block の内側で確定しており、順序がスレッドのタイミングに依存していないこと。`DispatchSemaphore` で完了 block を停止させる方式を使っていないこと。`#if DEBUG` の seam は `0177` が `getStats` の完了 closure から消した `self` の読みを再導入していないこと。
- 追加したアクセサと seam が internal または `#if DEBUG` で、production から参照されておらず、公開 API と Release の挙動が変わっていないこと。`make api-check-fresh` が成功し、`TestConsumers/Swift6Consumer/ApiBaseline/` に差分が無いこと。
- 追加したテストとアクセサのコメントが日本語で、issue 番号を含まないこと。
- 実ネットワークへ接続せず、追加したテストが 10 回連続で成功し、`SoraTests` 全体が失敗 0 件であること。モックやスタブを使っていないこと。
- `make fmt-lint` と `make lint` が成功すること。
- `CHANGES.md` の `## develop` の `### misc` に `[ADD]` で参照保持 box の回帰テストの追加が追記され、公開 API と利用者の挙動の変更がないことが補足されていること。

## 解決方法
