# DataChannel シグナリング切断経路 E2E テストを追加する

- Priority: Low
- Created: 2026-07-10
- Completed:
- Model: GPT-5
- Branch: feature/add-e2e-datachannel-close-test
- Polished:

## 目的

DataChannel シグナリング有効時に切断が DataChannel 経由で正しく伝播することを検証する E2E テストを追加する。JS SDK の `e2e-tests/tests/type_close.test.ts` 相当のテストを行う。

## 現状

iOS SDK の `PeerChannel` には DataChannel 切断経路が実装済み:
- `switchedToDataChannel = true` で DataChannel 切り替え後に WebSocket を切断
- Sora から `type: "close"` を受信すると `dataChannelSignalingClose` にステータスコードを格納
- `reason == .dataChannelClosed` 時に `SoraError.dataChannelClosed` を生成

E2E テストが存在しない。

## 設計方針

`dataChannelSignaling = true` + `ignoreDisconnectWebSocket = true` で接続し、サーバー側切断 API で切断をトリガーする。切断イベントが DataChannel 経由で伝播し、切断理由が適切であることを確認する。

テストの流れ:
1. `dataChannelSignaling = true` + `ignoreDisconnectWebSocket = true` で sendonly 接続
2. `onReceiveSignalingJSON` で `type: "switched"` の受信を待機（DataChannel 切り替え完了の確認）
3. Sora API でサーバー側から切断
4. `onDisconnect` で切断理由が `.dataChannelClosed` であることを確認
5. `SoraError.dataChannelClosed` のステータスコードと reason を検証

JS SDK の実装を参考にする: `e2e-tests/tests/type_close.test.ts`

注意: Sora API へのアクセスが必要。到達不可の場合は `XCTSkip` でスキップする。

## テスト方針

- モック・スタブは使用しない
- 実機 E2E テストとして `E2ETests` に追加
- Sora API 未到達時は XCTSkip

## 完了条件

- DataChannel シグナリング切り替え後、サーバー側切断で切断理由が適切に伝播すること
- `onDisconnect` の error が `SoraError.dataChannelClosed` であること

## 解決方法
