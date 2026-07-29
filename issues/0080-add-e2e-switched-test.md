# DataChannel シグナリング切り替え (type: switched) E2E テストを追加する

- Priority: Low
- Created: 2026-07-10
- Completed:
- Model: GPT-5
- Branch: feature/add-e2e-switched-test
- Polished:

## 目的

DataChannel シグナリング有効時に `type: "switched"` メッセージを受信し、WebSocket から DataChannel へ切り替わることを検証する E2E テストを追加する。JS SDK の `e2e-tests/tests/type_switched.test.ts` 相当のテストを行う。

## 現状

iOS SDK の `PeerChannel` には `type: "switched"` の受信と DataChannel 切り替え処理 (`switchedToDataChannel = true`) が実装済み。E2E テストが存在しない。

## 設計方針

`dataChannelSignaling = true` で接続し、`MediaChannelHandlers.onReceiveSignalingJSON` で `type: "switched"` を含む JSON を受信することを確認する。

テストの流れ:
1. `dataChannelSignaling = true` で sendonly 接続
2. `onReceiveSignalingJSON` で受信した JSON をパースし、`type` フィールドが `"switched"` であるメッセージが含まれることを確認
3. 特定の `type: "switched"` メッセージの `ignore_disconnect_websocket` フィールドを検証

JS SDK の実装を参考にする: `e2e-tests/tests/type_switched.test.ts`

注意: DataChannel シグナリング機能は Sora サーバー側で有効化されている必要がある。未対応のサーバーでは `XCTSkip` でスキップする。

## テスト方針

- モック・スタブは使用しない
- 実機 E2E テストとして `E2ETests` に追加
- Sora サーバーが DataChannel シグナリング未対応の場合は XCTSkip

## 完了条件

- `dataChannelSignaling = true` で接続後、`type: "switched"` メッセージを受信すること
- 受信した `switched` メッセージの `ignore_disconnect_websocket` フィールドが検証できること

## 解決方法
