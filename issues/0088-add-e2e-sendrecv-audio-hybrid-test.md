# sendrecv 音声の双方向を iOS とヘッドレスブラウザのハイブリッドで検証する E2E テストを追加する

- Priority: Medium
- Created: 2026-08-07
- Completed:
- Model: deepseek-v4-pro
- Branch: feature/add-e2e-sendrecv-audio-hybrid-test
- Polished:

## 目的

2 台の sendrecv クライアントによる「互いの音声受信」を検証する E2E テストを追加する。iOS では同一プロセスで 2 つの音声デバイス（`RTCAudioDeviceModule` / `DummyAudioDevice` の AUAudioUnit）を同時に起動できない可能性が高いため、片方のクライアントをヘッドレスブラウザ（Playwright + sora-js-sdk）で実行することで、iOS 側の音声デバイスを 1 つに抑えて双方向の音声通信を検証する。

## 背景

`0075-add-e2e-sendrecv-test` は映像のみの sendrecv テストであり、音声の受信は iOS のオーディオアーキテクチャ上の制約（同一プロセスで 2 つの音声デバイスを同時起動できない）により対象外とした。音声の受信（inbound audio）は E2E テストシリーズ全体でも未検証のまま残っている。

本 issue は、片方のクライアントをヘッドレスブラウザで実行することでこの制約を回避し、音声の双方向受信を検証する。

## 現状

- iOS の E2E テスト（`SoraTests/SignalingE2ETests.swift`）は Simulator で CI 実行される（`.github/workflows/ci.yml` の `e2e` ジョブ）
- sora-js-sdk には Playwright ベースの E2E テスト基盤と `sendrecv` テストページが存在する（`e2e-tests/tests/sendrecv.test.ts`）
- 音声の送信は `testSendonlyDummyAudio`（0068 で実装済み）で検証されているが、受信は未検証

## 設計方針

- sendrecv1: iOS（XCTest / Simulator）— `DummyAudioDevice` で音声送信（iOS 側の音声デバイスは 1 つ）
- sendrecv2: ヘッドレスブラウザ（Playwright + sora-js-sdk）— `getUserMedia` の fake media で音声送信
- 両者を同一チャンネルに接続し、両方の audio の outbound / inbound / codec stats を確認する

テストの流れ:

1. 共有するチャンネル ID を決定する（CI の run_id 等を使用）
2. ヘッドレスブラウザを sendrecv2 として接続する（Playwright）
3. iOS を sendrecv1 として接続する（XCTest）
4. 両方の接続完了後、5 秒待機する
5. 両方の `getStats` で audio の inbound / outbound / codec（`audio/opus`）stats を確認する
6. 両方を切断する

## 課題

- **CI 連携**: sora-ios-sdk の CI から sora-js-sdk の Playwright を起動する仕組みが必要（npm 依存、テストページの配信）
- **同期**: チャンネル ID の共有と接続タイミングの調整が必要（CI スクリプトで「Playwright をバックグラウンド起動 → iOS テスト実行」の順序制御）
- **テスト基盤**: XCTest と Playwright の 2 つのテストコードを保守する必要がある

## 完了条件

- iOS とヘッドレスブラウザが同一チャンネルで接続し、互いの音声を受信できること
- 両方の audio inbound / outbound stats が確認できること
- CI で安定して実行できること

## 解決方法
