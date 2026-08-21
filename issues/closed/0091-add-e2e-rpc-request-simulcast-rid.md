# RPC (RequestSimulcastRid) の E2E テストを追加する

- Priority: Medium
- Created: 2026-08-20
- Completed: 2026-08-20
- Model: deepseek-v4-pro
- Branch: feature/add-e2e-rpc-request-simulcast-rid
- Polished: 2026-08-20

## 目的

RPC 機能で simulcast の受信 rid を切り替えられることを E2E で検証する。sora-js-sdk の `e2e-tests/tests/rpc.test.ts` (RequestSimulcastRid) に相当する。

## 優先度根拠

- RPC は Sora 2025.2.0 で追加された実験的機能であり、`rpc()` の実接続における往復と副作用 (rid 切替) は E2E でしか担保できない
- Android SDK では同様の検証 (issue 0071) が完了済みだが、iOS SDK には RPC の E2E テストがない
- 両 rid (r0 / r2) が立ち上がらない環境ではテストがスキップになるため Medium とする

## 現状

- `MediaChannel.rpc(method:params:)` は実装済み (`MediaChannel.swift` の `rpc`) だが、実接続で RPC の往復を検証する自動テストがない
- SDK は offer の `data_channels` に `rpc` ラベルがあり、その DataChannel が OPEN になった時点で `rpcChannel` を設定する (`PeerChannel.swift` の `rpcChannel`)。`rpc_methods` の内容は SDK の有効化判定には使われておらず、払い出しのゲートは Sora サーバー側の挙動である
- `rpc()` は `rpcChannel` が設定されるまで `SoraError.rpcUnavailable` で失敗する。そのため RPC 実行前に rpc ラベルの `onDataChannelOpened` 待機が必要
- `RequestSimulcastRid` / `RequestSimulcastRidParams` / `RequestSimulcastRidResult` は `RPCTypes.swift` に定義済み

## 環境前提

RPC 機能は認証成功時に `rpc_methods` を払い出す必要がある。js-sdk の e2e テストでは、**テストサーバー固有の機能**として JWT の private claims に以下を埋め込み、サーバー側がこれを検証して認証成功時の払い出しに反映している (`e2e-tests/rpc/main.ts` の `privateClaims`、Android の `SoraRpcE2ETest` も同一方式)。**通常の Sora では本テストは動作しない**。

recvonly クライアントの JWT に埋め込む private claims:

- `rpc_methods`: `["2025.2.0/RequestSimulcastRid"]`
- `simulcast`: `true`
- `simulcast_request_rid`: `"r2"`
- `simulcast_rpc_rids`: `["none", "r0", "r1", "r2"]`

sendonly クライアントは通常の JWT（private claims なし）で接続する。

また、接続先 Sora の設定で `data_channel_signaling` と `data_channel_rpc` が有効であること。加えて、払い出される `simulcast_encodings` で r0 の `scaleResolutionDownBy` が **2.0** に調整されていること（理由は「検証手段」参照）。この調整の反映方法（JWT の claim かサーバー側の設定か）はテストサーバー実装依存のため、着手時に確認する

### 着手時の確認タスク

1. 接続先サーバーが上記の払い出し（private claims の検証と認証成功時の反映）に対応しているか確認する。Android SDK の issue 0071 実装時の対応状況を確認し、iOS の E2E テストが使う接続先が同じテストサーバーであることを確認する。未対応の場合は、テストサーバー側の対応を別 issue として依頼する
2. **テスト内で claims 付き JWT を生成する方法**を確定する。Android は `JwtGenerator` で秘密鍵 (`TEST_SECRET_KEY`) からテスト内で生成している（payload には `channel_id` を含み、テストサーバーがこれを検証する）。iOS には JWT 生成機能がないため、テストコード内で HS256 JWT を生成する実装（CryptoKit 等）が必要。`buildChannelId(unique: true)` で生成したチャンネル ID を `channel_id` に埋め込むこと。`E2ETestBase.buildConfiguration` は `TEST_SECRET_KEY` をそのまま `metadata.access_token` に設定するだけのため、claims 付き JWT を `signalingConnectMetadata` に設定できる仕組みをテスト側で用意する
3. iOS libwebrtc の `getStats` で `inbound-rtp` の `frameWidth` / `frameHeight` が取得できるか確認する（既存の E2E テストでは `bytesReceived` / `packetsReceived` しか使っていない）。`frameWidth` はデコード済みフレームの幅であり、受信デコードが有効でないと取得できない可能性がある。**まずは VideoRenderer を装着せずに取得できるかを確認する**（iOS では `Configuration.videoEnabled = true`（デフォルト）で受信デコードが動作する可能性が高い。Android の `enableVideoDownstream` に相当する専用 API は iOS にはない）。取得できない場合は、受信ストリームの `MediaStream.videoRenderer` への VideoRenderer 装着等でデコードを有効化する手段を確認し、それでも取得できない場合はテストフローの検証方法（`framesDecoded` の変化等）を見直す
4. **recvonly 1 台（r2 購読）構成で、sendonly の r0 / r2 の両方が `bytesSent > 0` になるか**確認する。issue 0076 の実測では「r0 のみ購読時に r2 の `bytesSent` が 0 のままになる」事象があり、購読者のいないレイヤーがエンコードされない可能性がある。r0 が立ち上がらない場合は、r0 購読用の recvonly をもう 1 台追加する等の構成変更を本 issue に反映する。また、RPC で r0 に切り替えた後、r2 購読者がいなくなるため、r2 に戻した際にサーバーが r2 のエンコードを再開できるか（RequestSimulcastRid の副作用に再エンコードが含まれるか）も併せて確認する
5. `senderConnectionId` を省略した `RequestSimulcastRidParams(rid: .r0)` が接続先 Sora で機能することを確認する。機能しない場合は params に `senderConnectionId` を含める方式に変更する

## 設計方針

### 検証手段

- rid 切替の効果は**受信映像の解像度変化**で確認する。`getStats()` の `inbound-rtp` の `frameWidth` / `frameHeight` が、RPC 実行前後で変化することを検証する。値の取り出しは `(entry.values["frameWidth"] as? NSNumber)?.intValue` で行う（`E2ETestBase.inboundVideoByteCounts` の `as? NSNumber` パターン）
- 解像度差の前提: `simulcast_encodings` で r0 の `scaleResolutionDownBy` を 2.0 に調整した場合、r0 = 一辺 1/2（960x540 なら 480x270）、r2 = 元解像度（960x540）。デフォルトの 4.0 ではエンコーダ負荷で r0 が立ち上がらず `bytesSent` が 0 のままになる可能性があり、Android SDK の issue 0071 では実測で 2.0 にすると r0 が立ち上がることを確認済み。r0 と r2 の間に明確な解像度差があるため、`frameWidth` / `frameHeight` の比較で切り替えを検出できる
- `simulcast.switched` 通知の `current_rid` による確認は**行わない**。理由: iOS SDK の `SignalingNotify` に `current_rid` フィールドが存在しない (`Signaling.swift`) ため、型安全には取得できない
- モック・スタブは使用しない（実接続 E2E のみ。DummyVideoCapturer は実装済みのダミーソースを使用する）

### チャネル構成

- sendonly チャネル: `simulcastEnabled = true` + `videoBitRate = 1200` + `videoCodec = .vp8` + `audioEnabled = false` + `initialCameraEnabled = false` + DummyVideoCapturer (960x540 / **15fps**)。`SimulcastE2ETests.testSimulcastDummyVideo` の構成を踏襲する（960x540 / 1200 kbps は Sora ドキュメントの simulcast で 3 ストリームに必要な値。15fps は Simulator の CPU 負荷でレイヤーエンコードが維持されなくなるのを防ぐため）
- recvonly チャネル: `simulcastEnabled = true` + `simulcastRequestRid = .r2` + `dataChannelSignaling = true` + `ignoreDisconnectWebSocket = true` + `videoCodec = .vp8` + `audioEnabled = false`。RPC はこのチャネルのみで実行する
- 両チャネルは**同一 Sora ルーム（同一 channelId）**に接続する。`buildChannelId(unique: true)` で一意なチャンネル ID を生成し、2 台で共用する
- 接続・ハンドラ登録・後始末は既存の E2E テストと同じパターン（connect 前のハンドラ登録、main queue への束ね、`disconnectAll` / `disconnectAndVerify`、未 fulfill の expectation は `XCTWaiter.wait(for:timeout: 0)` で後始末）

### RPC 呼び出し

- RPC メソッドは `RequestSimulcastRid.self`、パラメータは `RequestSimulcastRidParams(rid: .r0)` の形式で `MediaChannel.rpc(method:params:)` を呼び出す
- `rpc()` は async throws で戻り値が `RPCResponse<M.Result>?` のため、テストからは Task 内で `guard let response = try await channel.rpc(...)` により非 nil を確認し、結果の検証は main queue に束ねてから expectation を fulfill する（SoraTests には async/await の先例がないため、このパターンを明示する）。失敗時（throw）も main queue に束ねて XCTFail し、expectation を fulfill する
- `response.result.rid` が要求した rid であることを確認する
- `rpc()` のタイムアウトはデフォルト (5.0 秒) を利用する（`MediaChannel.rpc` の `timeout` パラメータ）。呼び出し側の `wait(for:)` のタイムアウトは 10 秒とし、`rpc()` 内部のタイムアウトと競合しないようにする

### テストフロー

```
1. sendonly チャネルを接続 (simulcast 有効)。connect コールバック内で DummyVideoCapturer を生成し
   channel.senderStream に接続する (SimulcastE2ETests と同じパターン)
2. recvonly チャネルを接続 (simulcast 有効 + requestRid .r2 + dataChannelSignaling + claims 付き JWT)
3. 両チャネルの接続完了を待つ
4. recvonly チャネルの offer で rpc ラベルと rpc_methods の存在を確認 (スキップ判定は「スキップ判定」参照)
5. recvonly チャネルの switched 受信を待つ (testSendonlySwitched と同じパターン)
   (ステップ 4 の offer 判定と switched 受信は到着順が保証されないため、両方ともハンドラ内で
   フラグ化し、switched 待機完了後に offer 判定の結果を確認する)
6. recvonly チャネルの rpc ラベルの onDataChannelOpened を待つ (rpc() が rpcUnavailable にならないようにする)
7. capturer.start() を呼び出し、映像送信を開始
8. sendonly チャネルの outbound-rtp を rid 別に分類し、r0 と r2 の両方で bytesSent > 0 になるまでポーリング
   (SimulcastE2ETests の simulcastOutboundVideoStats と同じ方法。5 秒間隔 × 最大 5 回)
9. recvonly チャネルの inbound-rtp で frameWidth > 0 になるまで待機 (1 秒間隔 × 最大 10 回) し、
   解像度を 2 回サンプル (3 秒間隔) して一致することを確認して初期解像度 (r2) とする
   (レイヤーフォールバック等で r2 以外の解像度をサンプルすると、以降の「初期解像度より小さい」検証が
   成立しなくなるため。一致しない場合は待機を継続し、タイムアウト時は失敗とする)
10. rpc() で rid を r0 に切り替え、response.result.rid が r0 であることを確認
11. frameWidth が初期解像度より小さくなるまでポーリング (1 秒間隔 × 最大 10 回)
    (RPC 切替前にデコード済みの旧 r2 解像度が stats に残っているレースを避けるため、
    1 回目の getStats で判定せず、小さくなるまで継続する)
12. ステップ 11 のポーリングで最後に観測した frameWidth / frameHeight が初期解像度 (r2) より小さいことを確認
    (js-sdk の toBeLessThan 相当。width / height 両方を比較)
13. rpc() で rid を r2 に戻し、response.result.rid が r2 であることを確認
14. frameWidth がステップ 11 で観測した r0 の値より大きくなるまでポーリング (1 秒間隔 × 最大 10 回)
15. ステップ 14 のポーリングで最後に観測した frameWidth / frameHeight が r0 の値より大きいことを確認
```

- タイムアウト値: 接続 35 秒 × 2 / switched 受信 10 秒 / rpc DataChannel OPEN 待機 10 秒 / 送信側 rid ポーリング 25 秒 / 初期解像度待機 10 秒 + サンプル 6 秒 / 解像度変化ポーリング 10 秒 × 2 / rpc() 呼び出しの wait 10 秒 × 2。全体は約 3 分弱
- 各待機の失敗時（タイムアウト）は、受信側 inbound-rtp の実測値（レポート有無 / bytesReceived / frameWidth）を含むメッセージで失敗とする

### スキップ判定

- recvonly チャネルの offer で以下を確認し、満たさない場合は後始末を実行してから XCTSkip でスキップする (testSendonlySwitched の offer 判定パターン):
  - `data_channels` に `rpc` ラベルが含まれる
  - `rpc_methods` に `2025.2.0/RequestSimulcastRid` が含まれる
  - `simulcast` が `true`
- ステップ 8 で r0 と r2 の両方の `bytesSent > 0` が観測できない場合はスキップする（購読者のいないレイヤーがエンコードされない、またはシミュレータ制約による rid 未生成のため）。スキップメッセージには sendonly outbound-rtp の rid 別 bytesSent の実測値を含める
- **両 rid が立ち上がっているのに解像度が変化しない場合は失敗とする**（機能故障の検出）

## 完了条件

- `rpc()` で rid を切り替え、その効果を受信映像の解像度変化 (inbound-rtp の frameWidth / frameHeight) で確認する E2E テストが追加されていること。r2 に戻した際の解像度復帰も検証すること
- 前提条件 (rpc_methods 払い出し) を満たさない環境、および送信側で対象 rid が立ち上がらない環境ではテストがスキップされること
- **CI シミュレータ（iPhone 17 Pro / iOS 26.5）でテストがパスすること（スキップのみでの完了は不可）**。ただし、本 issue のチャネル構成（recvonly 1 台）では購読者のいないレイヤーがエンコードされない可能性があるため、確認タスク 4 の結果に応じて構成を確定したうえでパスを確認する（スキップが常態化する場合は r0 購読チャネルの追加等を反映してパス可能な状態にする）
- `CHANGES.md` の develop セクションの `### misc` に追記されていること

## 変更対象ファイル

- `SoraTests/RpcE2ETests.swift`（新規）
- `SoraTests/E2ETestBase.swift`（`SimulcastE2ETests` の `simulcastOutboundVideoStats` は private で再利用できないため、rid 別 outbound 分類ヘルパーを E2ETestBase に移動して共有する。0089 の共通ヘルパー集約方針に従う。なお `hasSimulcastOutboundVideo`（r0 / r1 / r2 の 3 レイヤー完全一致判定）は本テストで使わないため、r0 / r2 の 2 レイヤーを確認する判定は RpcE2ETests 側に実装する）
- `SoraTests/SimulcastE2ETests.swift`（ヘルパー移動に伴う変更）
- `CHANGES.md`

## 依存関係

- issue 0090 (closed 済み。`onDataChannelOpened` の追加): rpc ラベルの OPEN を `onDataChannelOpened` で検知するため。現行実装では `rpcChannel` 設定後に防御的通知が行われるため、`onDataChannelOpened` 発火時点で `rpc()` が利用可能

## 解決方法

`SoraTests/RpcE2ETests.swift` に `testSendrecvDataChannelMessaging` を追加した。

- sendonly（simulcast 送信）+ recvonly（RPC 実行）の 2 チャネル構成。
  - sendonly: `simulcastEnabled` + `videoBitRate = 1200` + `videoCodec = .vp8` + `audioEnabled = false` + `initialCameraEnabled = false` + DummyVideoCapturer（960x540 / 15fps）。SimulcastE2ETests の構成を踏襲
  - recvonly: `simulcastEnabled` + `simulcastRequestRid = .r2` + `dataChannelSignaling` + `ignoreDisconnectWebSocket` + `videoCodec = .vp8` + `audioEnabled = false`
- claims 付き JWT は `E2ETestBase.buildJWTAccessToken` でテスト内生成する（HS256 / CryptoKit）。payload の `channel_id` は引数の値で強制上書きする（テストサーバーの検証に使用）
- `E2ETestBase` に `simulcastOutboundVideoStats` を移動し、SimulcastE2ETests と共有する（0089 の方針）
- 検証フロー:
  1. recvonly の offer で `rpc` ラベル / `rpc_methods` / `simulcast` を確認（満たさなければ XCTSkip）
  2. recvonly の switched 受信と `rpc` ラベルの OPEN を待機
  3. sendonly の outbound-rtp を rid 別に分類し、r0 / r2 の両方で `bytesSent > 0` を確認（立ち上がらなければ XCTSkip）
  4. recvonly の inbound-rtp で frameWidth / frameHeight を 2 回サンプルして初期解像度（r2）を確定
  5. `rpc()` で r0 に切替 → frameWidth / frameHeight が初期解像度より小さくなることを確認
  6. `rpc()` で r2 に戻す → frameWidth / frameHeight が r0 より大きくなることを確認
- 検証ヘルパー: `waitForOutboundR0AndR2`（rid 立ち上がり待機）、`waitForStableInboundFrameSize`（初期解像度サンプル）、`waitForInboundFrameSize`（解像度変化ポーリング、predicate と失敗メッセージを `InboundFrameSizeCondition` で対に保持）。`getStats` の一時的な failure はリトライで吸収する（SimulcastE2ETests と同じ方針）
- タイムアウト: シナリオ全体 150 秒（ポーリングの最悪系所要時間を吸収）
- ビルド（build-for-testing）と SwiftLint は通過済み

### 検証結果（E2E テスト実行）

ローカル E2E 実行（シミュレータ）でテストがパスすることを確認した。これにより、着手時の確認タスクはすべて解決済み:

- テストサーバーの `rpc_methods` 払い出し: 対応済みであることを確認（offer の `rpc_methods` に `2025.2.0/RequestSimulcastRid` が含まれる）
- `frameWidth` / `frameHeight` の取得: VideoRenderer 装着なしで `getStats` から取得できることを確認
- recvonly 1 台構成での r0 / r2 エンコード維持: 両方立ち上がることを確認（構成変更は不要）
- `senderConnectionId` 省略: 省略で機能することを確認
