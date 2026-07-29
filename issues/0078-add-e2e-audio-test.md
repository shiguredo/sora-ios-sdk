# sendonly audio E2E テストを追加する

- Priority: Medium
- Created: 2026-07-10
- Completed:
- Model: GPT-5
- Branch: feature/add-e2e-audio-test
- Polished:

## 目的

音声のみの送信 (sendonly audio) を検証する E2E テストを追加する。JS SDK の `e2e-tests/tests/sendonly_audio.test.ts` 相当のテストを行う。

## 現状

既存の iOS E2E テストに音声送信のテストが存在しない。`testSendonlyDummyVideo` は `audioEnabled = false` でテストしているため、音声パスの動作確認ができていない。

## 設計方針

音声のみ有効 (`videoEnabled = false, audioEnabled = true`) で sendonly 接続し、音声が送信されていることを `getStats` で確認する。

テストの流れ:
1. `role = .sendonly`、`videoEnabled = false`、`audioEnabled = true` で接続
2. 接続後、`getStats` で outbound audio stats を取得
3. `bytesSent > 0` かつ `packetsSent > 0` であることを確認

JS SDK の実装を参考にする: `e2e-tests/tests/sendonly_audio.test.ts`

## テスト方針

- モック・スタブは使用しない
- 実機 E2E テストとして `E2ETests` に追加

## 完了条件

- 音声のみの sendonly 接続が成功すること
- `getStats` の outbound audio stats で bytes/packets が確認できること

## 解決方法
