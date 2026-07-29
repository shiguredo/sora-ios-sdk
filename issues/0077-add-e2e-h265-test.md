# H.265 E2E テストを追加する

- Priority: Medium
- Created: 2026-07-10
- Completed:
- Model: GPT-5
- Branch: feature/add-e2e-h265-test
- Polished:

## 目的

H.265 コーデックでの接続を検証する E2E テストを追加する。JS SDK の `e2e-tests/tests/h265.test.ts` 相当のテストを行う。

## 現状

既存の iOS E2E テストに H.265 コーデックのテストが存在しない。H.265 のパラメーター送信 (0011) や TURN-TLS (0021) など H.265 関連の機能が増えており、E2E での動作確認が必要。

## 設計方針

既存の `testSendonlyDummyVideo` を参考に、`videoCodec = .h265` で sendonly 接続を行う。DummyVideoCapturer でダミー映像を H.265 エンコードで送信し、`getStats` で `codecType == "H265"` のエンコーダが使用されていることを確認する。

テストの流れ:
1. `videoCodec = .h265` で sendonly 接続
2. DummyVideoCapturer でダミー映像送信
3. 接続後、`getStats` で outbound codec stats を取得し `video/H265` が存在することを確認

JS SDK の実装を参考にする: `e2e-tests/tests/h265.test.ts`

## テスト方針

- モック・スタブは使用しない
- 実機 E2E テストとして `E2ETests` に追加
- 一部の iOS デバイスでは H.265 エンコード非対応の可能性があるため、テストスキップ判定を入れる

## 完了条件

- H.265 コーデックで sendonly 接続が成功すること
- `getStats` の outbound codec stats に `video/H265` が含まれること

## 解決方法
