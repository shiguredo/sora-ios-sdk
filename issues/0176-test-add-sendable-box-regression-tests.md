# 参照保持 box の同一性判定と `close()` の回帰テストを追加する

- Created: 2026-09-28
- Completed: {YYYY-MM-DD}
- Priority: Low
- Branch: feature/refactor-add-sendable-box-regression-tests
- Polished: {YYYY-MM-DD}

## 目的

`0173` が `Sora/MediaChannel.swift` の `getStats` と `Sora/NativePeerChannelFactory.swift` の `createClientOfferSDP` に追加した参照保持 box (`@unchecked Sendable`) が担っている 2 つの振る舞いを、回帰テストで固定する。

- `MediaChannel.getStats` の完了 block 内の `currentPeerConnection === context.peerConnection` の同一性判定
- `NativePeerChannelFactory.createClientOfferSDP` の完了 block の内側での `context.peerConnection.close()`

この 2 つは型検査では守れない。box が保持する `RTCPeerConnection` の型を変えずに別のオブジェクトを渡す変更も、`close()` の呼び出しを削る変更も、型は変わらないため診断が出ない。`0173` はこの 2 経路にテストを追加せず、型検査と `SoraTests` 全体を回帰の正本とした (「`MediaChannel.getStats` は `state` を `.connected` にする経路が private のため単体 harness を作らない」)。型検査で守れない部分だけをテストで補うのが本 issue である。

## 優先度根拠

利用者に見える挙動と公開 API を変えないテストの追加であり、実装済みの変更に対する補強であるため Low とする。ただし `0173` の box の安全性は日本語コメントでしか説明されておらず、コメントと実装がずれても検出できないため、放置はしない。

## 現状

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

`Sora/NativePeerChannelFactory.swift` の `createClientOfferSDP` は、局所名 `peer2` の一時 `RTCPeerConnection` と handler を `ClientOfferSDPCreationContext` へ移し、`peer2.offer(for:)` の完了 block の最後で一時 PC を閉じる。

```swift
  private final class ClientOfferSDPCreationContext: @unchecked Sendable {
    let handler: (String?, (any Error)?) -> Void
    let peerConnection: RTCPeerConnection
```

```swift
    let context = ClientOfferSDPCreationContext(handler: handler, peerConnection: peer2)
    peer2.offer(for: webRTCConfiguration.nativeConstraints) { sdp, error in
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

- `testFactoryCreatesActualADMForStereoPlayout` と `testFactoryCreatesActualADMWithoutStereoPlayout`、および stereo playout と AudioSession の各テスト (`testStereoCategoryFollowsSenderRole` / `testMediaChannelDeinitClosesNativePeerConnectionAndReleasesRequirement` など) は `RTCAudioDeviceModule` と `AudioSessionCoordinator` の要求数を観測する。box は観測しない。
- `getStats` を呼ぶテストは実 Sora へ接続する E2E (`SendonlyE2ETests` / `SendrecvE2ETests` / `SimulcastE2ETests` / `RpcE2ETests` / `StereoAudioOutputE2ETests`) だけであり、`Statistics` の内容を確認する。同一性判定と `nativeChannel` の差し替えは確認していない。
- 実 `RTCPeerConnection` の close の観測前例は `SoraTests/StereoAudioOutputTests.swift` の `testMediaChannelDeinitClosesNativePeerConnectionAndReleasesRequirement` にある。`peerChannel.nativeChannel = nativeChannel` で実 PC を設定し、`MediaChannel` の解放後に `XCTAssertEqual(nativeChannel.connectionState, .closed)` で確認している。

### `getStats` の単体 harness が無い理由

- `Sora/MediaChannel.swift` の `state` は `public private(set) var state: ConnectionState = .disconnected` であり、`.connected` を代入する経路は `private func finishConnect(connectionTask:)` の 1 箇所だけである。`finishConnect` は `MediaChannel.basicConnect(connectionTask:)` の `peerChannel.connect` 完了 handler から呼ばれ、実際のシグナリング接続の成功を前提にする。
- `getStats` は先頭で `guard state == .connected` を満たさない場合に handler へ failure を返して return するため、`.connected` へ到達できない単体テストでは box の判定まで進まない。
- `SoraTests/StereoAudioOutputTests.swift` の `testConnectFinishesAfterSoraIsReleased` は到達不能な URL (`wss://127.0.0.1:1`) で接続失敗を期待しており、実ネットワークなしに `.connected` へ到達する経路は無い。
- `0164` の調査のとおり redirect は `connect` への応答としてのみ届き、WebRTC 接続確立後にサーバーから送られることはない。したがって実 Sora へ接続する E2E でも、`.connected` 中に `nativeChannel` が別の `RTCPeerConnection` へ差し替わる状況は作れない。

### テスト用アクセサの前例

- `Sora/ConnectionTimer.swift` の `currentGeneration` は、doc コメントに「実運用では使用しない」と書かれた read-only の internal アクセサで、テストから世代の管理と検証に使う。
- `Sora/MediaChannel.swift` の `isConnectionTimerRunning` は「接続タイマーの終端状態を回帰テストから確認するための内部アクセサーです。」と doc コメントを持つ read-only の internal アクセサである。
- `Sora/ScreenCapture.swift` の `setMediaChannelConnectionRequiredForTesting(_:)` は「テストのために internal とする。本番では常に `true` のままで、この setter は呼びません。」と doc コメントを持つテスト専用 setter である。
- `Sora/StreamFrameOwner.swift` の `processedSequencesForTesting` は `#if DEBUG` で囲み、production には観測用の状態を持ち込まない形の前例である。

## 前提となる issue

- `0173` (完了 2026-09-28): box の追加元。`## スコープ外` と `## 解決方法` が「`MediaChannel.getStats` は `state` を `.connected` にする経路が private のため単体 harness を作らない」と記録しており、本 issue はこの判断の穴を埋める。
- `0177` (open): `#SendableClosureCaptures` の残り 11 件のうち `0177` が扱う 10 件に、`MediaChannel.getStats(handler:)` の `RTCPeerConnection.statistics` 完了 closure が捕捉する `self` と `self.peerChannel.nativeChannel` の読みが含まれる。`getStats` の box の使われ方も変わり得るため、`getStats` 側のテストは `0177` の後、または `0177` の設計が確定した後に実施する。`0177` が box を置き換える場合は、本 issue の同一性判定のテスト対象を `0177` 後の実装へ読み替える。
- `0164` (open): redirect が接続確立前にのみ届くことの調査。本 issue が内部アクセサを使う根拠である。
- `0118` (完了 2026-09-25) と `0171` (open): `SoraTests` は Swift 6 言語モードで build され、`0171` の完了後は warnings-as-errors になる。追加するテストは concurrency 診断を出さない書き方にする。

## 設計方針

モックやスタブは使わず、実 `RTCPeerConnection` と実 `MediaChannel` / 実 `NativePeerChannelFactory` だけで観測する。

### 一時 PC の `close()` の観測

- `Sora/NativePeerChannelFactory.swift` に、`createClientOfferSDP` が作った一時 PC をテストから参照するための internal な `weak` アクセサ (例: `lastClientOfferPeerConnectionForTesting`) を追加し、`createClientOfferSDP` の `peer2` の生成直後に代入する。`weak` にするのは、production の参照寿命と Release の挙動を変えないためである。`#if DEBUG` で囲む (前例 `StreamFrameOwner.processedSequencesForTesting`)。
- テストは `createClientOfferSDP` の handler の内側でアクセサから一時 PC を取り出してテスト側で強参照し、同じ handler の内側で `RTCPeerConnectionDelegate` を設定する。handler は `close()` より前に呼ばれるため、delegate の設定は `close()` に間に合う。delegate は `peerConnection(_:didChange:)` の `.closed` で `XCTestExpectation` を fulfill する。`RTCPeerConnectionDelegate` の `didChangeConnectionState` は `@optional` のため、テストクラスはこのメソッドだけを実装できる。
- `close()` が削られた場合も、box が `peer2` 以外のオブジェクトを保持して実際の一時 PC が閉じられない場合も、`.closed` へ遷移せず timeout するため失敗する。
- 実装時に `.closed` の delegate 通知が届かない場合は、`connectionState` を 10 ms 間隔・上限 5 秒で確認する条件待ちに置き換える (実 `RTCPeerConnection` の `connectionState` が `.closed` になることは `testMediaChannelDeinitClosesNativePeerConnectionAndReleasesRequirement` で観測済みである)。

### `getStats` の同一性判定の観測

- `Sora/MediaChannel.swift` にテスト用の internal アクセサ (例: `setConnectionStateForTesting(_:)`) を追加し、実接続を伴わずに `.connected` を作る。`connectionLifecycleLock` 配下で設定し、`#if DEBUG` で囲み、production では呼ばないことを日本語コメントで書く。名前と粒度は `ScreenCapture.setMediaChannelConnectionRequiredForTesting(_:)` に揃える。
- 実 `NativePeerChannelFactory` で `RTCPeerConnection` を 2 つ (`pcA` / `pcB`) 作り、`peerChannel.nativeChannel` で差し替える。`MediaChannel.peerChannel` と `PeerChannel.nativeChannel` は internal であり、`SoraTests/StereoAudioOutputTests.swift` と `SoraTests/PeerChannelRedirectInvalidationTests.swift` が既に同じ設定方法を使っている。
- 成功側: `state` を `.connected` にし、`peerChannel.nativeChannel = pcA` で `getStats` を呼び、handler が success で 1 回だけ呼ばれることを `XCTestExpectation` で固定する。box が `pcA` 以外のオブジェクトを保持する変更が入ると同一性判定が不一致になり handler が failure を返すため、このテストが落ちる。
- 不一致側: `getStats` を呼んだ後に `peerChannel.nativeChannel` を `pcB` へ差し替え、handler が failure で 1 回だけ呼ばれることを固定する。同一性判定が削除または `!= nil` の確認へ書き換わると handler が success を返すため、このテストが落ちる。`state` は `.connected` のままなので、失敗は同一性判定の分岐 (`nativeChannel changed`) だけから返る。差し替えは `PeerChannel.createAndSendAnswer(offer:)` による `nativeChannel` の置き換え (redirect 相当) と同じ状態を作る。
- box が旧 `RTCPeerConnection` の参照を保持していること自体は、弱参照の生存では観測しない。統計の完了前は box 以外の参照の有無で結果が変わり得るため、観測点は handler が返す結果にする。box が統計要求時のオブジェクトを参照し続けていることは、差し替え後も一致しないこと (failure になること) で固定する。
- 差し替えが statistics の完了 block より前に確定することをテスト内で保証する。先に実 PC の `statistics` 完了 block を `DispatchSemaphore` で停止させ、停止中に `getStats` を呼び、`nativeChannel` を差し替えてから停止を解除する。停止は timeout 付きにしてテストがハングしないようにする。この順序保証が実 `RTCPeerConnection` で成立しないと判明した場合は、タイミング依存の assert にせず、`RTCPeerConnectionDelegate` の callback を使うなどの別の順序保証へ置き換える。

### internal アクセサの是非

- 採用する。`getStats` の box の判定は `.connected` を前提にし、`.connected` へは private な `finishConnect` からしか到達できない。`0164` のとおり redirect は接続確立前に届くため E2E でも `.connected` 中の差し替えを作れず、実接続を使わずに判定へ到達する手段が他に無い。
- 反対意見への回答: `state` を直接代入するアクセサは接続ライフサイクルの契約を迂回する。`connectionLifecycleLock` 配下に限定し、`#if DEBUG` で囲んで Release に代入経路を残さず、テストは後始末で `state` を戻すか `MediaChannel` を解放する。production の経路は変更しない。
- 採らない案: `MediaChannelGetStatsContext` を internal にして同一性判定だけを単体で呼ぶ案は、box に渡すオブジェクトをテスト自身が決めるため「`getStats` が正しいオブジェクトを box へ渡しているか」を検出できない。E2E だけで観測する案は `.connected` 中の差し替えを作れず、不一致側を検出できない。

### その他

- public API のシグネチャと利用者に見える挙動を変えない。追加するアクセサは internal または `#if DEBUG` であり、公開 API baseline に現れない。
- 追加するテストとアクセサのコメントに issue 番号を書かない。ソースコードには理由そのものを書く。

## スコープ外

- `0177` が扱う `MediaChannel.getStats(handler:)` の `self` 捕捉の解消と、`Sora` target に残る他の 9 件の `#SendableClosureCaptures`。本 issue は box の判定の回帰テストだけを扱う。
- `0108` の Sora target warnings-as-errors ゲートと `0171` の test target warnings-as-errors ゲートの導入、および警告の解消。
- `PeerChannel.handleSignalingOverWebSocket(_:)` の `case .ping` にある統計 pong の送信経路。同じ `nativeChannel` の差し替えを見るが、box ではなく `isCurrentPeerConnection` を使う別の経路であり、`0127` が扱う。
- `MediaChannel.getStats` の実装の書き換え (0177 の担当) と、box の doc コメントの変更。本 issue はテストとテスト用アクセサの追加に限る。
- `0173` が追加した他の box (`Sora/PeerChannel.swift` の `CreateAnswerHandlerBox` / `Sora/CameraVideoCapturer.swift` の `CameraOperationCompletionBox` / `Sora/ConnectionTimer.swift` の `ConnectionTimerHandlerBox`) の回帰テスト。本 issue は同一性判定と `close()` を持つ 2 経路に限る。`createAnswer` の handler 呼び出し契約は `0175` が扱う。

## 変更対象

- `Sora/NativePeerChannelFactory.swift`: 一時 PC を参照するテスト用の internal アクセサ (例: `lastClientOfferPeerConnectionForTesting`) の追加と、`createClientOfferSDP` での代入
- `Sora/MediaChannel.swift`: `.connected` を作るテスト用の internal アクセサ (例: `setConnectionStateForTesting(_:)`) の追加
- `SoraTests/`: 参照保持 box の回帰テストを追加する (新規 `SoraTests/SendableBoxRegressionTests.swift` を想定)
  - `createClientOfferSDP` の一時 PC が `.closed` へ遷移すること
  - `getStats` が同一の `RTCPeerConnection` のままなら success を返し、差し替え後は failure を返すこと
  - `NativePeerChannelFactory` と `MediaChannel` を `tearDown` で解放し、テストが作った `RTCPeerConnection` を `close()` する後始末
- `CHANGES.md`: `## develop` の `### misc` に `[ADD]` で「参照保持 box の同一性判定と `close()` の回帰テストを追加する」を追記し、公開 API と利用者の挙動の変更がないことを補足行に書く (担当者行 `- @t-miya` を含める)

## テスト方針

モックやスタブは使用しない。

- 実ネットワークへ接続しない。`Sora.connect` と `SignalingChannel` を使わず、`MediaChannel` と `NativePeerChannelFactory` を直接作り、実 `RTCPeerConnection` の `connectionState` と `statistics` だけを使う。
- WebRTC の callback は別スレッドから届くため、handler の内側では assertion を記録せず、可変状態は lock で排他するか main queue へ hop してから検証する。前例は `SoraTests/PeerChannelRedirectInvalidationTests.swift` の `PeerChannelSDPResult` と `SoraTests/SendonlyE2ETests.swift` の `getStats` handler である。`getStats` の handler は `@Sendable` ではないため `@MainActor` のテストから渡すと MainActor 隔離を継承する。handler には `@Sendable` を明示し、非 `Sendable` な `MediaChannel` / `RTCPeerConnection` は handler の内側へ持ち込まず、Sendable な値へ写してから main queue へ渡す。
- `XCTestExpectation` は「handler が呼ばれたこと」と「`.closed` への遷移」の両方で使い、`wait` の後に handler の引数と回数を検証する。成功側と不一致側は別の expectation で待ち、`handler` が 1 回だけ呼ばれることも確認する。
- 後始末: `peerChannel.nativeChannel` の PC とテストが保持する PC を `close()` する。`RTCPeerConnectionFactory` は `RTCPeerConnection` と track より長生きさせる必要があるため、`NativePeerChannelFactory` を instance で保持し `tearDown` で解放する (前例 `SoraTests/PeerChannelRedirectInvalidationTests.swift` の `peerConnectionFactory`)。停止用の `DispatchSemaphore` は timeout 付きで必ず解放する。
- 退行検出の確認: 追加したテストが現行の実装で成功し、`createClientOfferSDP` の `context.peerConnection.close()` を削った作業ツリーと、`getStats` の `currentPeerConnection === context.peerConnection` を削った作業ツリーのそれぞれで失敗することを確認する。確認用の変更は commit しない。
- 追加したテストを単独で 10 回以上実行し、flaky でないことを確認する。E2E は実行しない (実 Sora を必要とするため)。
- `SoraTests` 全体を実行して失敗 0 件であること。`make fmt-lint` と `make lint` が成功すること。`make api-check-fresh` が成功し、`git diff --exit-code -- TestConsumers/Swift6Consumer/ApiBaseline/` が空であること。
- 追加したテストが Swift 6 言語モードで concurrency 診断を出さないこと (`SoraTests` を build する `.github/workflows/e2e-test.yml` の invocation で確認する)。

## 完了条件

- `createClientOfferSDP` の一時 PC の `close()` を削ると失敗し、現行の実装で成功するテストがあること。
- `getStats` の同一性判定を削除または書き換えると失敗し、現行の実装で成功するテストがあること。同一の `RTCPeerConnection` のままなら success、差し替え後は failure を返すことの両方が固定されていること。
- 差し替えが statistics の完了 block より前に確定することがテスト内で保証されており、タイミング依存の assert になっていないこと。保証できないと判明した場合は、その理由と代替の検証内容が「解決方法」に記録されていること。
- 追加したアクセサが internal または `#if DEBUG` で、production から参照されておらず、公開 API と Release の挙動が変わっていないこと。`make api-check-fresh` が成功し、`TestConsumers/Swift6Consumer/ApiBaseline/` に差分が無いこと。
- 追加したテストとアクセサのコメントが日本語で、issue 番号を含まないこと。
- 実ネットワークへ接続せず、追加したテストが 10 回連続で成功し、`SoraTests` 全体が失敗 0 件であること。モックやスタブを使っていないこと。
- `make fmt-lint` と `make lint` が成功すること。
- `CHANGES.md` の `## develop` の `### misc` に `[ADD]` で参照保持 box の回帰テストの追加が追記され、公開 API と利用者の挙動の変更がないことが補足されていること。

## 解決方法
