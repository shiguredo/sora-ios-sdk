# 正常切断時の disconnect イベントを検証する E2E テストを追加する

- Priority: Medium
- Created: 2026-07-10
- Completed:
- Model: GPT-5
- Branch: feature/add-e2e-disconnect-event-test
- Polished:

## 目的

正常切断時の `disconnect` イベント（コード・理由・切断種別）を検証する E2E テストを追加する。JS SDK の `e2e-tests/tests/disconnect_event_type.test.ts` 相当および `onDisconnect` ハンドラの検証を行う。

## 現状

既存の iOS E2E テストには recvonly の接続・切断確認 (`testConnectRecvonly`、`testDisconnectRecvonly`) があるが、切断イベントの詳細検証（コード 1000、reconnect フラグ等）は不足している。`testDisconnectRecvonly` は正常切断コード 1000 の確認のみ。

## 設計方針

recvonly で接続後、`onDisconnect` ハンドラで切断イベントを検証する。既存の `testDisconnectRecvonly` を拡張し、以下の項目を確認する:

テストの流れ:
1. recvonly で接続
2. `channel.disconnect(error: nil)` でクライアント側から正常切断
3. `onDisconnect` ハンドラで以下を検証:
   - `event` が `.ok` であること
   - コードが 1000 であること（正常切断）
   - reason が nil または想定された値であること
4. 切断後、`connectionState` が disconnected であること

JS SDK の実装を参考にする: `e2e-tests/tests/disconnect_event_type.test.ts`

## テスト方針

- モック・スタブは使用しない
- 実機 E2E テストとして `E2ETests` に追加

## 完了条件

- 正常切断時に切断イベントが正しく発火すること
- 切断コード 1000 が確認できること

## 解決方法
