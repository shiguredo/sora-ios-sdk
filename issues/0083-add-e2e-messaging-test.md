# DataChannel messaging 送受信と stats 検証 E2E テストを追加する

- Priority: Medium
- Created: 2026-07-10
- Completed:
- Model: GPT-5
- Branch: feature/add-e2e-messaging-test
- Polished:

## 目的

DataChannel 経由のメッセージ送受信と統計情報を検証する E2E テストを追加する。JS SDK の `e2e-tests/tests/messaging.test.ts` 相当のテストを行う。

## 現状

iOS SDK は `DataChannel` クラスで DataChannel 経由のメッセージ送受信をサポートしているが、E2E テストが存在しない。

## 設計方針

2 台のクライアントを同一チャンネルに接続し、DataChannel 経由でメッセージを送受信する。送受信後、`getStats` で DataChannel の統計情報を取得し、bytes/messages が増加していることを確認する。

テストの流れ:
1. sendrecv 2 台を接続（`dataChannels` 設定あり）
2. client1 で DataChannel が open するのを待機
3. client2 で DataChannel が open するのを待機
4. client1 → client2 にメッセージ送信、client2 で受信を確認
5. client2 → client1 にメッセージ送信、client1 で受信を確認
6. 両方で `getStats` を取得し、DataChannel stats (`data-channel` type) が存在し bytes/messages > 0 であることを確認
7. 切断

JS SDK の実装を参考にする: `e2e-tests/tests/messaging.test.ts`

## テスト方針

- モック・スタブは使用しない
- 実機 E2E テストとして `E2ETests` に追加

## 完了条件

- DataChannel 経由でメッセージが送受信できること
- `getStats` で DataChannel stats が確認できること（bytesSent/bytesReceived > 0, messagesSent/messagesReceived > 0）

## 解決方法
