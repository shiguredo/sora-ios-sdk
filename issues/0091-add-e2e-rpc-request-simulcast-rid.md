# RPC (RequestSimulcastRid) の E2E テストを追加する

- Priority: Medium
- Created: 2026-08-20
- Completed:
- Model: deepseek-v4-pro
- Branch: feature/add-e2e-rpc-request-simulcast-rid
- Polished:

## 目的

RPC 機能で simulcast の受信 rid を切り替えられることを E2E で検証する。sora-js-sdk の `e2e-tests/tests/rpc.test.ts` (RequestSimulcastRid) に相当する。

## 優先度根拠

- RPC は Sora 2025.2.0 で追加された実験的機能であり、`rpc()` の実接続における往復と副作用 (rid 切替) は E2E でしか担保できない
- Android SDK では同様の検証 (issue 0071) が完了済みだが、iOS SDK には RPC の E2E テストがない
- 両 rid (r0 / r2) が立ち上がらない環境ではテストがスキップになるため Medium とする

## 現状

- `MediaChannel.rpc(method:params:)` は実装済み (`MediaChannel.swift` の `rpc`) だが、実接続で RPC の往復を検証する自動テストがない
- RPC は「DataChannel シグナリング有効 + 認証時に `rpc_methods` を払い出し」が前提であり、offer の `data_channels` に `rpc` ラベルがあり `rpc_methods` が空でない場合のみ有効化される (`PeerChannel.swift` の `rpcChannel` 設定)
- `rpc()` は rpc ラベルの DataChannel が OPEN になり `rpcChannel` が設定されるまで `SoraError.rpcUnavailable` で失敗する。そのため RPC 実行前に rpc ラベルの `onDataChannelOpened` 待機が必要
- `RequestSimulcastRid` / `RequestSimulcastRidParams` / `RequestSimulcastRidResult` は `RPCTypes.swift` に定義済み

## 環境前提

RPC 機能は認証成功時に `rpc_methods` を払い出す必要がある。js-sdk の e2e テストでは、**テストサーバー固有の機能**として JWT の private claims に以下を埋め込み、サーバー側がこれを検証して認証成功時の払い出しに反映している (`e2e-tests/rpc/main.ts` の `privateClaims`)。この機能は Sora 本体にはなく、テストサーバー固有の機能であるため、**通常の Sora では本テストは動作しない**。

recvonly クライアントの JWT に埋め込む private claims:

- `rpc_methods`: `["2025.2.0/RequestSimulcastRid"]`
- `simulcast`: `true`
- `simulcast_request_rid`: `"r2"`（初期受信 rid。本テストの検証 (r0 < r2) が成立する値であること）
- `simulcast_rpc_rids`: `["none", "r0", "r1", "r2"]`
- `simulcast_encodings`: r0 の `scaleResolutionDownBy` を **2.0** に調整する（デフォルトの 4.0 ではエンコーダ負荷で r0 が立ち上がらず、`bytesSent` が 0 のままになる可能性がある。Android SDK の issue 0071 では実測で 2.0 にすると r0 が立ち上がることを確認済み。例: `[{"rid": "r0", "scaleResolutionDownBy": 2.0}, {"rid": "r1", "scaleResolutionDownBy": 2.0}, {"rid": "r2", "scaleResolutionDownBy": 1.0}]`）

sendonly クライアントは通常の JWT（private claims なし）で接続する。

また、接続先 Sora の設定で `data_channel_signaling` と `data_channel_rpc` が有効であること。

### 着手時の確認タスク

1. 接続先サーバーが「JWT の private claims を検証し、認証成功時の払い出し（`rpc_methods` 等）に反映する」テストサーバー固有機能に対応しているかを確認する。Android SDK の issue 0071 実装でテストサーバー側は対応済みの可能性が高いが、iOS の E2E テストが使う接続先が同じテストサーバーであることを確認する。未対応の場合は、テストサーバー側の対応を別 issue として依頼する
2. iOS libwebrtc の `getStats` で `inbound-rtp` の `frameWidth` / `frameHeight` が取得できることを確認する（既存の E2E テストでは `bytesReceived` / `packetsReceived` しか使っていない）。取得できない場合は `framesDecoded` 等の変化で代替する
3. シミュレータの SW エンコーダで r0 と r2 の両方が立ち上がり、初期受信 (r2) との解像度差が実際に成立することを確認する
4. `senderConnectionId` を省略した `RequestSimulcastRidParams(rid: .r0)` が接続先 Sora で機能することを確認する。機能しない場合は params に `senderConnectionId` を含める方式に変更する

## 設計方針

### 検証手段

- rid 切替の効果は**受信映像の解像度変化**で確認する。`getStats()` の `inbound-rtp` の `frameWidth` / `frameHeight` が、RPC 実行前後で変化することを検証する
- 解像度差の前提: `simulcast_encodings` で r0 の `scaleResolutionDownBy` を 2.0 に調整した場合、r0 = 一辺 1/2（960x540 なら 480x270）、r2 = 元解像度（960x540）。r0 と r2 の間に明確な解像度差があるため、`frameWidth` / `frameHeight` の比較で切り替えを検出できる
- `simulcast.switched` 通知の `current_rid` による確認は**行わない**。理由: iOS SDK の `SignalingNotify` に `current_rid` フィールドが存在しない (`Signaling.swift`) ため、型安全には取得できない（Android SDK の issue 0071 と同じ判断）

### チャネル構成

- sendonly チャネル: `simulcastEnabled = true` + `videoBitRate = 1200` + DummyVideoCapturer (960x540 / 30fps) + VP8。`SimulcastE2ETests.testSimulcastDummyVideo` の構成を踏襲する（960x540 / 1200 kbps は Sora ドキュメントの simulcast で 3 ストリームに必要な値）
- recvonly チャネル: `simulcastEnabled = true` + `simulcastRequestRid = .r2` + `dataChannelSignaling = true` + `ignoreDisconnectWebSocket = true`。RPC はこのチャネルのみで実行する
- 両チャネルは**同一 Sora ルーム（同一 channelId）**に接続する。`buildChannelId(unique: true)` で一意なチャンネル ID を生成し、2 台で共用する

### RPC 呼び出し

- RPC メソッドは `RequestSimulcastRid.self`、パラメータは `RequestSimulcastRidParams(rid: .r0)` の形式で `MediaChannel.rpc(method:params:)` を呼び出す
- `rpc()` は async throws のため、テストからは Task 内で呼び出し、結果の検証は main queue に束ねる
- 戻り値の `RPCResponse<RequestSimulcastRid.Result>` が成功し、`result.rid` が要求した rid であることを確認する

### テストフロー

```
1. sendonly チャネルを接続 (simulcast 有効)
2. recvonly チャネルを接続 (simulcast 有効 + requestRid .r2 + dataChannelSignaling)
3. 両チャネルの接続完了を待つ
4. recvonly チャネルの offer で rpc ラベルと rpc_methods の存在を確認 (スキップ判定は「スキップ判定」参照)
5. recvonly チャネルの switched 受信を待つ (testSendonlySwitched と同じパターン)
6. recvonly チャネルの rpc ラベルの onDataChannelOpened を待つ (rpc() が rpcUnavailable にならないようにする)
7. capturer.start() を呼び出し、映像送信を開始
8. sendonly チャネルの outbound-rtp を rid 別に分類し (SimulcastE2ETests の simulcastOutboundVideoStats と同じ方法)、
   r0 と r2 の両方で bytesSent > 0 になるまでポーリング (10 回 × 1 秒)
9. recvonly チャネルの inbound-rtp で frameWidth > 0 になるまで待機 (10 秒) し、
   安定のため 3 秒待機して初期解像度 (r2) をサンプル (js-sdk rpc.test.ts のパターン)
10. rpc() で rid を r0 に切り替え、RPCResponse の result.rid が r0 であることを確認
11. 解像度変化をポーリング (10 回 × 1 秒)
12. r0 の frameWidth と frameHeight が初期解像度 (r2) より小さいことを確認 (js-sdk の toBeLessThan 相当。width / height 両方を比較)
13. rpc() で rid を r2 に戻し、解像度が初期解像度に戻る（または r0 より大きくなる）ことを
    ステップ 11 と同じポーリングで確認 (js-sdk rpc.test.ts のパターン)
```

- タイムアウト値: 接続 35 秒 × 2 / switched 受信 10 秒 / rpc DataChannel OPEN 待機 10 秒 / 送信側 rid ポーリング 10 秒 / 初期解像度サンプル 10 秒 / 解像度変化ポーリング 10 秒
- 各待機の失敗時（タイムアウト）は、受信側 inbound-rtp の実測値（レポート有無 / bytesReceived / frameWidth）を含むメッセージで失敗とする

### スキップ判定

- recvonly チャネルの offer で以下を確認し、満たさない場合は後始末を実行してから XCTSkip でスキップする (testSendonlySwitched の offer 判定パターン):
  - `data_channels` に `rpc` ラベルが含まれる
  - `rpc_methods` に `2025.2.0/RequestSimulcastRid` が含まれる
  - `simulcast` が `true`
- 送信側 rid ポーリングで、startCapture 後に r0 と r2 の両方で `bytesSent > 0` が観測できない場合のみスキップする（シミュレータ制約による rid 未生成のため）。この場合は RPC の実行を含め検証は一切行われず、テスト全体がスキップされる。**両 rid が立ち上がっているのに解像度が変化しない場合は失敗とする**（機能故障の検出）
- スキップメッセージには、sendonly outbound-rtp の rid 別 bytesSent の実測値を含める

## 完了条件

- `rpc()` で rid を切り替え、その効果を受信映像の解像度変化 (inbound-rtp の frameWidth / frameHeight) で確認する E2E テストが追加されていること。r2 に戻した際の解像度復帰も検証すること
- 前提条件 (rpc_methods 払い出し) を満たさない環境、および送信側で対象 rid が立ち上がらない環境ではテストがスキップされること。対象 rid が立ち上がっているのに解像度が変化しない場合は失敗とすること
- **両 rid (r0 / r2) が立ち上がる環境（実機等）で、テストがパスすること（スキップのみでの完了は不可）**。どの環境で実測確認するかは、実装時に決定し issue に記録する
- `CHANGES.md` の develop セクションの `### misc` に追記されていること

## 変更対象ファイル

- `SoraTests/RpcE2ETests.swift`（新規）
- `CHANGES.md`

## 依存関係

- issue 0090 (onDataChannelOpened の発火タイミング変更): `onDataChannelOpened` で rpc ラベルの OPEN を検知するため

## 解決方法
