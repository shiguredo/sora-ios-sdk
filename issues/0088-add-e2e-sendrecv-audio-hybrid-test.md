# sendrecv 音声の双方向を検証する E2E テストを追加する

- Priority: Medium
- Created: 2026-08-07
- Completed:
- Model: deepseek-v4-pro
- Branch: feature/add-e2e-sendrecv-audio-hybrid-test
- Polished: 2026-09-24

## 目的

2 台の sendrecv クライアントによる「互いの音声受信」を検証する E2E テストを追加する。まず iOS の Simulator 上で 2 台の sendrecv を同一プロセスに接続して互いの音声を受信できるか検証し、できない場合の代替として、片方のクライアントをヘッドレスブラウザ（Playwright + sora-js-sdk）で実行して双方向の音声通信を検証する。

## 背景

`0075-add-e2e-sendrecv-test` は映像のみの sendrecv テストであり、音声の受信は「iOS では同一プロセスで 2 つの音声デバイスを同時に起動できない可能性が高い」との判断により対象外とした。Sora シグナリング（`MediaChannel`）経由の音声受信（inbound audio）は E2E テストシリーズでも未検証のまま残っている。

なお、この「可能性が高い」は実測によるものではなく、現在は状況が変わっている。`SoraTests/DummyStereoAudioLoopbackTests.swift` は、同一プロセスで 2 つの `DummyAudioDevice`（送信側・受信側）を同時に起動し、実 PeerConnection / Opus / ADM 経由で受信再生 PCM を検証している。`DummyAudioDevice` は `playoutHandler` を指定すると `AVAudioSession` と AUAudioUnit に触れず、録音は `pcmGenerator`、再生は callback で完全にソフトウェア動作する（`Sora/DummyAudioDevice.swift` の `initialize(with:)` / `initializePlayout()`）。そのため iOS 単独で 2 台の sendrecv を構成できる可能性が高い。

## 現状

- iOS の E2E テストは `SoraTests/` 配下のテスト種別ごとのクラスに分割されており、sendrecv は `SoraTests/SendrecvE2ETests.swift` の `testSendrecvDummyVideo`（ベースクラスは `SoraTests/E2ETestBase.swift`）。Simulator で CI 実行される（`.github/workflows/e2e-test.yml` の `e2e` ジョブ）
  - なお `SoraTests/SignalingE2ETests.swift` は 0089-refactor-split-e2e-tests で分割され存在しない
- sora-js-sdk には Playwright ベースの E2E テスト基盤と `sendrecv` テストページが存在する（`e2e-tests/tests/sendrecv.test.ts`、`e2e-tests/sendrecv/`）。また、ブラウザ内で生成した音声を送信する `e2e-tests/fake_stereo_audio_sendrecv/` も develop に存在する
- 音声の送信は `testSendonlyDummyAudio`（0068 で実装済み）で検証されているが、受信は未検証

## 設計方針

- 第 1 案（推奨）: sendrecv1 / sendrecv2 とも iOS（XCTest / Simulator）。同一 `Sora()` インスタンスに 2 つの `MediaChannel` を接続し（0075 の `testSendrecvDummyVideo` と同じ流れ）、それぞれに `playoutHandler` と `pcmGenerator` を指定した `DummyAudioDevice` を設定する。AVAudioSession の競合と AUAudioUnit の同時起動を避け、音声ハードウェアに依存しない
- 第 2 案（第 1 案が不安定・動作しない場合の代替）: sendrecv1 = iOS（`DummyAudioDevice` で音声送信）、sendrecv2 = ヘッドレスブラウザ（Playwright + sora-js-sdk の `sendrecv/` または `fake_stereo_audio_sendrecv/`）。ブラウザ側の音声は `getUserMedia` の fake media の場合 Playwright の起動引数（`--use-fake-device-for-media-stream` 等）で偽装するか、ブラウザ内生成の音声を使用する。iOS 側も `playoutHandler` を指定し、シミュレーターで RemoteIO が利用できない場合（0068 の制限事項）に備える
- 両者を同一チャンネルに接続し、両方の audio の outbound / inbound / codec stats を確認する

テストの流れ（第 2 案の場合）:

1. 共有するチャンネル ID を決定する。CI の Sora サーバーは `e2e-test` を含み、かつ `TEST_CHANNEL_ID_PREFIX` / `TEST_CHANNEL_ID_SUFFIX`（`_${{ github.run_id }}`）を組み合わせた channelId だけを許可するため、ブラウザ側も同じ条件に合わせる（0075 の「Sora サーバー要件」参照。iOS 側は `E2ETestBase.buildChannelId(unique: true)` を利用）
2. ヘッドレスブラウザを sendrecv2 として接続する（Playwright）
3. iOS を sendrecv1 として接続する（XCTest）
4. 両方の接続完了後、5 秒待機する
5. 両方の `getStats` で audio の inbound / outbound / codec（`audio/opus`）stats を確認する
6. 両方を切断する

## 課題

- **iOS 単独での実現性（第 1 案）**: 同一プロセスで 2 つの `DummyAudioDevice` を起動できることは `DummyStereoAudioLoopbackTests` で実証済みだが、Sora シグナリング（`MediaChannel`）経由で 2 接続した場合に動作することは未実証。`Configuration.audioDevice` の注入経路と `AVAudioSession` の扱いを実装時に確認する
- **CI 連携（第 2 案）**: sora-ios-sdk の CI から sora-js-sdk の Playwright を起動する仕組みが必要（リポジトリの追加 checkout、npm 依存、テストページの配信）
- **同期（第 2 案）**: チャンネル ID の共有と接続タイミングの調整が必要（CI スクリプトで「Playwright をバックグラウンド起動 → iOS テスト実行」の順序制御）
- **テスト基盤（第 2 案）**: XCTest と Playwright の 2 つのテストコードを保守する必要がある

## 完了条件

- 2 台の sendrecv クライアントが同一チャンネルで接続し、互いの音声を受信できること
- 両方の audio inbound / outbound stats が確認できること
- CI で安定して実行できること

## 解決方法
