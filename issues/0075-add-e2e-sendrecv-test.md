# sendrecv E2E テストを追加する

- Priority: Medium
- Created: 2026-07-10
- Completed:
- Model: GPT-5
- Branch: feature/add-e2e-sendrecv-test
- Polished:

## 目的

双方向通信 (sendrecv) の E2E テストを追加する。JS SDK の `e2e-tests/tests/sendrecv.test.ts` 相当のテストを iOS 実機で実現する。2 台の sendrecv クライアントが互いの映像・音声を受信できることを確認する。

## 現状

既存の iOS E2E テストは recvonly 接続確認 (`testConnectRecvonly`) と sendonly ダミー映像送信 (`testSendonlyDummyVideo`) のみ。双方向通信のテストが存在しない。

## 設計方針

既存の `E2ETests` にテストケースを追加する。2 台の sendrecv クライアントを別チャンネルではなく同一チャンネルで接続し、それぞれが相手の映像・音声を受信できることを WebRTC 統計情報で確認する。

テストの流れ:
1. sendrecv1 を接続（音声・映像有効、DummyVideoCapturer でダミー映像送信）
2. sendrecv2 を接続（音声・映像有効、DummyVideoCapturer でダミー映像送信）
3. 5 秒待機後、両方の `getStats` を取得
4. 両方に outbound video stats（送信）と inbound video stats（受信）が存在し、bytes/packets > 0 であることを確認

JS SDK の実装を参考にする: `e2e-tests/tests/sendrecv.test.ts`

## テスト方針

- モック・スタブは使用しない
- 実機で実行する E2E テストとして `E2ETests` に追加
- 環境変数 `TEST_SECRET_KEY` 未設定時は XCTSkip でスキップ

## 完了条件

- sendrecv 2 台が同一チャンネルに接続し、互いの映像・音声を送受信できること
- `getStats` で inbound/outbound 両方の stats が確認できること
- タイムアウト: 120 秒（2 台接続 + 待機のため既存より長め）

## 解決方法
