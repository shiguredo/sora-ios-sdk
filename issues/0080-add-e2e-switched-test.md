# DataChannel シグナリング切り替え (type: switched) E2E テストを追加する

- Priority: Low
- Created: 2026-07-10
- Completed:
- Model: GPT-5
- Branch: feature/add-e2e-switched-test
- Polished: 2026-08-13

## 目的

DataChannel シグナリング有効時に `type: "switched"` メッセージを受信し、シグナリングが WebSocket から DataChannel へ切り替わることを検証する E2E テストを追加する。JS SDK の `e2e-tests/tests/type_switched.test.ts` 相当の検証を行う。

## 現状

iOS SDK の `PeerChannel` には `type: "switched"` の受信と DataChannel 切り替え処理（`switchedToDataChannel = true`）が実装済み。E2E テストが存在しない。

## 設計方針

`dataChannelSignaling = true` と `ignoreDisconnectWebSocket = true` で sendonly 接続し、`MediaChannelHandlers.onReceiveSignalingJSON` で `type: "switched"` メッセージの受信と `ignore_disconnect_websocket` フィールドを検証する。あわせて、シグナリングが DataChannel 経由に切り替わったタイミングで呼ばれる `MediaChannelHandlers.onDataChannel` の発火を確認する。

js-sdk のテストは `transportType == "websocket"` を検証しているが、iOS の `onReceiveSignalingJSON` は送信元情報を持たないため、切り替えの検証は `onDataChannel` の発火で行う。なお `switched` は WebSocket 経由でのみ処理されるため、`onReceiveSignalingJSON` での受信確認は WebSocket 経由の受信を意味する。

ハンドラの登録は `configuration.mediaChannelHandlers` 経由で `sora?.connect` 呼び出しより前に行う（`switched` は接続完了（`onConnect`）より先に到着し得るため、connect コールバック内での登録は取りこぼしのリスクがある）。`onReceiveSignalingJSON` は WebSocket 受信スレッドと DataChannel の delegate スレッドから呼ばれるため、受信 JSON の記録と expectation の fulfill は `DispatchQueue.main.async` で main queue に束ねる（`E2ETestBase` は @MainActor）。

テストの流れ:

1. テスト固有の一意なチャンネル ID を生成する（`buildChannelId(unique: true)`）
2. sendonly の Configuration を構築する（`role: .sendonly`、`dataChannelSignaling: true`、`ignoreDisconnectWebSocket: true`、`videoEnabled: true`、`audioEnabled: false`、`videoCodec: .vp8`、`initialCameraEnabled: false`）。生成した `channelId` を `config.channelId` に上書きする。`configuration.mediaChannelHandlers` に `onReceiveSignalingJSON`（受信 JSON の記録）と `onDataChannel`（切り替え検知 expectation の fulfill）を登録してから接続する
3. 接続完了を待つ（wait 35 秒。ConnectionTimer が `Configuration.connectionTimeout` の 30 秒で発火するため、その発火を wait 内で処理する）。接続失敗時（`onConnect` が error を受けた場合）は `XCTFail` して後始末へ進む。接続成功後、connect コールバック内で `channel.senderStream` を取得して DummyVideoCapturer（640×480 @ 30fps）を生成・開始する
4. 受信したシグナリング JSON から、offer に `data_channels` フィールドが含まれるかを確認する（SDK と同じく `dict["data_channels"] is [Any]` のキャスト判定で確認する）
   - offer に `data_channels` が含まれない場合は、後始末（capturer 停止 + 切断）を実行してから XCTSkip でスキップする（サーバー未対応と SDK の不具合を区別するため、`switched` の受信タイムアウトではスキップしない）
5. `onReceiveSignalingJSON` で受信した JSON を `JSONSerialization` でパースし、`type == "switched"` のメッセージの受信を待つ（wait 10 秒。offer / notify / ping 等の他のメッセージも流れるため `type` フィールドでフィルタする。パースできない JSON は無視する）。受信できない場合は XCTFail とする（SDK の回帰を検出する）
6. 受信した `switched` メッセージの `ignore_disconnect_websocket` フィールドが `true` であることを確認する（クライアントの `ignoreDisconnectWebSocket: true` がサーバーに反映される）
7. `onDataChannel` が発火したことを確認する（`onDataChannel` は `switched` 受信時に発火し、SDK が `switchedToDataChannel = true` で切り替え処理を実行したことの確認になる。DataChannel 経由のシグナリングの実働は検証しない）
8. 後始末: capturer を停止し、チャンネルを切断する（`disconnectAndVerify`。`ignoreDisconnectWebSocket: true` のため切断メッセージは DataChannel 経由で送信されるが、`SoraCloseEvent.ok(code: 1000)` の検証はそのまま適用できる）

JS SDK の実装を参考にする: `e2e-tests/tests/type_switched.test.ts`

## テスト方針

- モック・スタブは使用しない
- `SendonlyE2ETests` に `testSendonlySwitched` として追加（Simulator での CI 実行を前提。`.github/workflows/ci.yml` の `e2e` ジョブ）
- 環境変数 `SORA_SIGNALING_URL` / `TEST_SECRET_KEY` が未設定の場合は、既存ヘルパー（`buildConfiguration`）の XCTSkip に委譲する
- `audioEnabled = false` のため、マイク権限は不要
- `initialCameraEnabled = false` を設定し、物理カメラの自動起動を抑止する（既存テストと同じ）
- タイムアウト: 接続 35 秒 + switched 受信待機 10 秒 + 切断 10 秒で、全体を 60 秒以内に収める

## Sora サーバー要件

- DataChannel シグナリング（`data_channel_signaling`）が有効であること（offer に `data_channels` フィールドが含まれること）
- `switched` メッセージに `ignore_disconnect_websocket` フィールドを含めること（SDK のデコーダはこのフィールドを必須としてデコードする）
- クライアントの `ignoreDisconnectWebSocket: true` の要求を受理し、`switched` の `ignore_disconnect_websocket` に `true` を返すこと
- `metadata.access_token` による認証を受け入れること（0071 と同じ）
- `e2e-test` を含む channelId を拒否しないこと

## 完了条件

- `testSendonlySwitched` が実装され、設計方針のテストの流れの全ステップを満たすこと
- `CHANGES.md` の develop セクションの `### misc` に追記されていること

## 解決方法
