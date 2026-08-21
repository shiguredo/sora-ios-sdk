# DataChannel シグナリング切断経路 E2E テストを追加する

- Priority: Low
- Created: 2026-07-10
- Completed:
- Model: GPT-5
- Branch: feature/add-e2e-datachannel-close-test
- Polished: 2026-08-20

## 目的

DataChannel シグナリング有効時に切断が DataChannel 経由で正しく伝播することを検証する E2E テストを追加する。sora-js-sdk の `e2e-tests/tests/type_close.test.ts` 相当のテストを行う。

## 優先度根拠

- `dataChannelSignaling` と `ignoreDisconnectWebSocket` の組み合わせは切断挙動が通常と異なり、回帰しやすい経路であるため E2E で担保する価値がある
- ただし、検証の核心はサーバー側の `data_channel_signaling_close_message` 設定に依存し、未対応環境では検証が制限されるため Low とする

## 現状

- iOS SDK の `PeerChannel` には DataChannel 切断経路が実装済み:
  - `switchedToDataChannel = true` で DataChannel 切り替え後に WebSocket を切断する（`ignoreDisconnectWebSocket`）
  - Sora から DataChannel 経由で `type: "close"` を受信すると `dataChannelSignalingClose` に `(code, reason)` を格納する（`PeerChannel.swift` の `handleSignalingOverDataChannel`。WebSocket 経由の close は `handleSignalingOverWebSocket` で無視される）
  - DataChannel が正常にクローズされ（`reason == .dataChannelClosed`）、かつ `dataChannelSignalingClose` が設定済みの場合に `SoraError.dataChannelClosed(statusCode:reason:)` を生成する（`PeerChannel.swift` の `basicDisconnect`）
  - `SoraError.dataChannelClosed` は `MediaChannel` の `internalDisconnect` で `SoraCloseEvent.ok(code:reason:)` に変換されて `onDisconnect` で通知される（`MediaChannel.swift` の `onDisconnect`。`SoraCloseEvent` は `.ok(code:reason:)` と `.error(Error)` の 2 ケースのみ）
- E2E テストが存在しない

## 設計方針

### 検証の核心

本テストの核心は「**切断が DataChannel 経由で伝播すること**」である。iOS SDK には送信シグナリングのフックがないため、Android SDK の issue 0068 が行った「`type: "disconnect"` が SENT / DATA_CHANNEL で送信されること」の検証は実装できない。

DataChannel 経路であることは、**ステップ 6 の「`type: "close"` の code / reason と `SoraCloseEvent.ok` の値が一致すること」の検証が成功した時点で保証される**。その理由:

- `onReceiveSignalingJSON` は WebSocket 経由と DataChannel 経由の両方で発火するため、close の受信自体は経路の証明にならない
- ただし、WebSocket 経由の close は `handleSignalingOverWebSocket` で無視される（`dataChannelSignalingClose` に格納されない）。その場合 `onDisconnect` は `SoraCloseEvent.ok(code: 1000, reason: "NO-ERROR")` になる（`MediaChannel.swift` の `internalDisconnect`。error == nil 経路）
- 一方、DataChannel 経由の close は `dataChannelSignalingClose` に格納され、`SoraError.dataChannelClosed` → `SoraCloseEvent.ok(code:reason:)` へ無変換で伝播する
- したがって、`.ok` の code / reason が受信した close の値と一致すること = DataChannel 経由の切断であることの証明になる

なお、`onDisconnect` の発火経路について: `ignoreDisconnectWebSocket = true` の場合でも WebSocket の切断イベント自体は発生する（switched 受信から約 10 秒後に切断される）が、`SignalingChannel` は `ignoreDisconnectWebSocket` によりこれを無視する（`SignalingChannel.swift`）。正常切断の `onDisconnect` は DataChannel のクローズ（`reason == .dataChannelClosed`）経由でしか発火しない。

### テストの流れ

1. テスト固有の一意なチャンネル ID を生成する（`buildChannelId(unique: true)`。Sora API のボディに `channel_id` を指定して切断するため、他テストのチャンネルを誤って切断しないよう一意化が必須）
2. `TEST_API_URL` が未設定の場合は XCTSkip する（`testSendonlyReconnect` と同じパターン）
3. sendonly 接続（`dataChannelSignaling = true` + `ignoreDisconnectWebSocket = true`）。構成は `testSendonlySwitched` と同様（`videoCodec = .vp8` / `audioEnabled = false` / `initialCameraEnabled = false` / DummyVideoCapturer）。`dataChannels` によるメッセージング用ラベルの払い出しは**不要**。ハンドラ（`onReceiveSignalingJSON` / `onDisconnect`）は connect 呼び出しより前に登録する
4. offer に `data_channels` フィールドが含まれることを確認する（スキップ判定。「XCTSkip 条件」参照）
5. switched 受信を待ち、`ignore_disconnect_websocket` が true であることを確認する（`testSendonlySwitched` と同じ確認。false の場合はサーバーが `ignoreDisconnectWebSocket` を尊重していないため XCTSkip）
6. Sora API (DisconnectConnection) でサーバー側から切断する（`testSendonlyReconnect` と同じパターン: `X-Sora-Target: Sora_20151104.DisconnectConnection` ヘッダ / ボディ `{"channel_id", "connection_id"}`。`connection_id` は `MediaChannel.connectionId` から取得）。API が失敗した場合は後始末を実行してから失敗とする（`testSendonlyReconnect` の `apiDisconnectSucceeded` フラグパターン）
7. `onReceiveSignalingJSON` で `type: "close"` を受信したことを記録し、code / reason を保持する
8. `onDisconnect` で `SoraCloseEvent` を受信し、以下を確認する:
   - 必須: `.ok(code:reason:)` であること（`SoraCloseEvent.error` でないこと）
   - close を受信できた場合のみ: `.ok` の code / reason が、ステップ 7 で受信した `type: "close"` の値と一致すること

- タイムアウト: 接続 35 秒 / switched 受信 10 秒 / Sora API 10 秒 / close 受信 10 秒 / 切断待機 10 秒（合計約 75 秒）
- 後始末: 既存 E2E と同じパターン（`disconnectAll` / `disconnectAndVerify`。切断済みチャンネルは state チェックでスキップされる）。Sora API 失敗時はサーバー切断が発生しないため、close 待機・切断待機の expectation を `XCTWaiter.wait(for:timeout: 0)` で後始末する（`testSendonlyReconnect` と同じパターン）

### XCTSkip 条件

- offer に `data_channels` フィールドが含まれない場合（DataChannel シグナリング未対応）: 後始末を実行してから XCTSkip（`testSendonlySwitched` と同じパターン）
- `TEST_API_URL` が未設定の場合: 接続前に XCTSkip（`testSendonlyReconnect` と同じパターン）
- switched の `ignore_disconnect_websocket` が false の場合: 後始末を実行してから XCTSkip（サーバーが `ignoreDisconnectWebSocket` を尊重しない環境のため）
- `type: "close"` を受信できなかった場合は **スキップしない**。ステップ 8 の「必須」検証（`.ok` であること）は実施し、close の code / reason の一致検証のみを省略する（`data_channel_signaling_close_message` 無効のサーバー設定が原因の可能性があるため。Android SDK の issue 0068 と同じ方針）
- switched 受信タイムアウトではスキップしない（SDK の不具合として XCTFail する）

## テスト方針

- モック・スタブは使用しない
- `SoraTests/SendonlyE2ETests.swift` に `testSendonlyDataChannelClose` として追加する（DataChannel シグナリング関連のテストが集約されているクラス）
- 環境変数 `SORA_SIGNALING_URL` / `TEST_SECRET_KEY` が未設定の場合は、既存ヘルパー（`buildConfiguration`）の XCTSkip に委譲する

## Sora サーバー要件

- 0080 と同じ（DataChannel シグナリング有効・`metadata.access_token` 認証・`e2e-test` を含む channelId の受理）
- `data_channel_signaling_close_message` が有効であること（`type: "close"` の送信。無効な場合は close 受信の一致検証が省略される）
- サーバー切断用 Sora API (DisconnectConnection) に到達可能であること（`TEST_API_URL` 環境変数）

## 完了条件

- サーバー側切断で `onDisconnect` が `SoraCloseEvent.ok(code:reason:)` として発火する E2E テストが追加されていること
- `type: "close"` を受信できた場合に、close の code / reason と `SoraCloseEvent.ok` の code / reason が一致すること（DataChannel 経由の切断であることの証明）
- 前提条件を満たさない環境（`data_channels` 非対応・`TEST_API_URL` 未設定・switched の `ignore_disconnect_websocket` が false）ではテストがスキップされること
- `CHANGES.md` の develop セクションの `### misc` に追記されていること

## 変更対象ファイル

- `SoraTests/SendonlyE2ETests.swift`（`testSendonlyDataChannelClose` を追加）
- `CHANGES.md`

## 依存関係

- issue 0080 (closed): switched 受信・offer 判定・XCTSkip のパターン
- issue 0079 (closed): Sora API (DisconnectConnection) による切断のパターン
- issue 0089 (closed): E2E テスト分割（`E2ETests` は存在しない）
- issue 0082 (open): クライアント側切断の切断イベント検証（本 issue はサーバー側切断の DataChannel 経路検証であり、検証対象は重複しない）

## 解決方法
