# Simulcast E2E テストを追加する

- Priority: Medium
- Created: 2026-07-10
- Completed:
- Model: GPT-5
- Branch: feature/add-e2e-simulcast-test
- Polished:

## 目的

サイマルキャスト (simulcast) の E2E テストを追加する。JS SDK の `e2e-tests/tests/simulcast.test.ts` 相当のテストを行う。

## 現状

既存の iOS E2E テストに simulcast のテストが存在しない。サイマルキャストは Sora の主要機能の一つであり、E2E での動作確認が必要。

## 設計方針

sendonly 1 台 + recvonly 1 台の組み合わせで simulcast をテストする。JS SDK の simulcast テストでは 1 ページ内に sendonly + recvonly の両方が埋め込まれているが、iOS では 2 つの `MediaChannel` を同一アプリから接続して実現する。

テストの流れ:
1. sendonly クライアントを simulcast 有効で接続（DummyVideoCapturer 使用）
2. recvonly クライアントを simulcast 有効 + `simulcastRequestRid` 指定で接続
3. 接続後、recvonly 側の `getStats` で inbound video stats が存在し、bytes/packets > 0 であることを確認
4. rid ごとの映像受信を確認

JS SDK の実装を参考にする: `e2e-tests/tests/simulcast.test.ts`

## テスト方針

- モック・スタブは使用しない
- 実機 E2E テストとして `E2ETests` に追加

## 完了条件

- simulcast sendonly + recvonly で映像が送受信できること
- rid ごとの inbound stats が確認できること

## 解決方法
