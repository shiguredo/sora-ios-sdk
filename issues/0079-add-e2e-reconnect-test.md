# reconnect E2E テストを追加する

- Priority: Medium
- Created: 2026-07-10
- Completed:
- Model: GPT-5
- Branch: feature/add-e2e-reconnect-test
- Polished:

## 目的

Sora の再接続 (reconnect) 機能を検証する E2E テストを追加する。JS SDK の `e2e-tests/tests/reconnect.test.ts` 相当のテストを行う。

## 現状

既存の iOS E2E テストに再接続のテストが存在しない。ネットワーク切断からの復旧は重要な機能であり、E2E での動作確認が必要。

## 設計方針

sendonly で接続後、サーバー側から切断 API を呼び出して切断させ、クライアントが再接続することを確認する。JS SDK では Sora API を利用してサーバー側切断をトリガーしている。

テストの流れ:
1. sendonly クライアントを接続（DummyVideoCapturer 使用）
2. Sora API（または puppeteer 相当のサーバー側操作）で切断
3. クライアント側で `onDisconnect` が発火し、切断理由が適切であることを確認
4. クライアントが自動再接続し、`onConnect` が再発火することを確認

JS SDK の実装を参考にする: `e2e-tests/tests/reconnect.test.ts`

注意: サーバー側 API へのアクセスが必要なため、iOS CI 環境から Sora API へ到達可能であることが前提。到達不可の場合は `XCTSkip` でスキップする。

## テスト方針

- モック・スタブは使用しない
- 実機 E2E テストとして `E2ETests` に追加
- Sora API 未到達時は XCTSkip でスキップ

## 完了条件

- サーバー側切断後にクライアントが再接続できること
- 切断理由が適切な値であること

## 解決方法
