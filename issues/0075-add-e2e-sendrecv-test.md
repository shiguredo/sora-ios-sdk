# sendrecv E2E テストを追加する

- Priority: Medium
- Created: 2026-07-10
- Completed:
- Model: GPT-5
- Branch: feature/add-e2e-sendrecv-test
- Polished: 2026-08-07

## 目的

双方向通信 (sendrecv) の E2E テストを追加する。2 台の sendrecv クライアントを同一チャンネルに接続し、互いの映像を受信できることを確認する。

音声は本 issue の対象外とする。iOS では同一プロセスで 2 つの音声デバイス（`RTCAudioDeviceModule` / `DummyAudioDevice` の AUAudioUnit）を同時に起動できない可能性が高く、2 台の sendrecv で「互いの音声受信」を確認するのは技術的に困難であるため。音声送信の検証は `testSendonlyDummyAudio`（0068 で実装済み）で行われており、本 issue では扱わない（音声の受信は E2E テストシリーズ全体でも未検証のまま残る点に注意）。

## 現状

既存の iOS E2E テスト（`SoraTests/SignalingE2ETests.swift`）には、recvonly 系（`testConnectRecvonly` / `testDisconnectRecvonly` / `testOfferAnswerCompleted`）と sendonly 系（`testSendonlyDummyVideo` / `testSendonlyDummyAudio`）が存在するが、双方向通信のテストが存在しない。

## 設計方針

既存の `E2ETests` にテストケース `testSendrecvDummyVideo` を追加する。同一 `Sora()` インスタンスに 2 つの `MediaChannel` を直列に接続し、それぞれが相手の映像を受信できることを WebRTC 統計情報で確認する。

接続結果は失敗フラグ（`connectFailed`）で管理し、接続失敗時は残りの `wait(for:)` と後続ステップをすべてスキップしてテストを終了する（`XCTFail` はテストメソッドを停止しないため、各 `wait(for:)` の後にフラグをチェックして `return` する）。

テストの流れ:

1. テスト固有の一意なチャンネル ID を生成し、両チャンネルで使用する。`config.channelId = "e2e-test-\(UUID().uuidString)"` で上書きする（`e2e-test` を含む形式は Sora サーバーの「`e2e-test` を含む channelId を拒否しない」要件に合致させる。既存ヘルパーの `TEST_CHANNEL_ID_PREFIX` / `TEST_CHANNEL_ID_SUFFIX` は意図的に使用しない）
2. sendrecv1 を接続する（`role: .sendrecv`、`videoEnabled: true`、`audioEnabled: false`、`videoCodec: .vp8`、`initialCameraEnabled: false`）。コールバックはシグナリングのキュー上で実行されるため、処理の実行スレッドに依存させず、main RunLoop 上での後続処理（待機・stats 取得）は `DispatchQueue.main.async` で行う
3. sendrecv1 の connect コールバック内で、`channel.senderStream` を取得して DummyVideoCapturer を設定・開始し、そのまま sendrecv2 を接続する。生成した capturer はテストメソッドスコープの変数に保持する（保持しないとコールバック終了時に解放され、フレーム送信が止まる）。接続した `MediaChannel` も同様に保持し、切断時に使用する（`sora?.mediaChannels.first` は配列の順序に依存するため使わない）
4. sendrecv2 の connect コールバック内で、同様に DummyVideoCapturer を設定・開始する
5. 接続完了を待つ（connect expectation 2 つを各 30 秒の `wait(for:timeout:)` で分けて直列に実行する）。接続失敗時（1 台目・2 台目とも）は、起動済みの capturer を stop して接続済みのチャンネルを切断し、`connectFailed` を true にして `XCTFail` し、expectation を fulfill する。wait から戻ったらフラグをチェックして `return` する
6. 5 秒待機する（両方の接続完了後からカウントする）。待機は main RunLoop 上の `Timer` で行い、`Thread.sleep` は使用しない（main RunLoop を止めると DummyVideoCapturer のフレーム送信が停止するため）
7. 両方の `getStats` を取得し、`type == "codec"` の `mimeType == "video/VP8"`・`type == "outbound-rtp"` の `kind == "video"` の `bytesSent` / `packetsSent`・`type == "inbound-rtp"` の `kind == "video"` の `bytesReceived` / `packetsReceived` を確認する
8. 両方を切断し、`onDisconnect` で正常切断コード (1000) を確認する

映像の受信は送信側エンコーダが最初の keyframe を送出するまで受信パケットが存在しない。そのため、5 秒待機後に `getStats` を取得し、**両チャンネルの inbound-rtp で `bytesReceived` / `packetsReceived` が 0 より大きいことを確認できた時点で打ち切る**。確認できない場合は 2 秒後に再取得し、初回を含めて最大 3 回試行する。3 回目の試行でも確認できない場合は `XCTFail` して expectation を fulfill し、codec / outbound 検証と切断確認をスキップしてテストを終了する。

codec stats と outbound-rtp の検証は、リトライが成功した場合のみ一度だけ行う。

`getStats` が `failure` を返した場合（接続済みでない場合等）は、起動済みの capturer を stop して切断し、即 `XCTFail` して expectation を fulfill し、後続ステップをスキップしてテストを終了する。

5 秒待機と stats リトライは 1 つの expectation に統合し、その `wait(for:timeout:)` は 30 秒とする。

JS SDK の実装を参考にする: `e2e-tests/tests/sendrecv.test.ts`

## テスト方針

- モック・スタブは使用しない
- `E2ETests` に追加（Simulator での CI 実行を前提。`.github/workflows/ci.yml` の `e2e` ジョブ）
- 環境変数 `SORA_SIGNALING_URL` / `TEST_SECRET_KEY` が未設定の場合は、既存ヘルパー（`buildConfiguration(role:)`）の XCTSkip に委譲する
- `audioEnabled = false` のため、マイク権限は不要
- `initialCameraEnabled = false` を設定し、物理カメラの自動起動を抑止する（既存テストと同じ）
- `videoCodec = .vp8` を明示指定する
- タイムアウト: 接続 30 秒 × 2 台 + 待機・stats リトライ 30 秒 + 切断 10 秒 × 2 台で、全体を 120 秒以内に収める
- DummyVideoCapturer は 30fps × 2 台で動作するため、Simulator では CPU 負荷が高い。問題が生じた場合は frameRate を下げる

## Sora サーバー要件

- 同一チャンネルへの sendrecv クライアントの同時 2 接続を受け付けること
- 音声トラックなし（`audioEnabled = false`）の sendrecv 接続を受け付けること
- VP8 をサポートしていること
- `metadata.access_token` による認証を受け入れること（0071 と同じ）
- `e2e-test` を含む channelId を拒否しないこと

## 完了条件

- `testSendrecvDummyVideo` が実装され、設計方針のテストの流れの全ステップを満たすこと
- `CHANGES.md` の develop セクションの `### misc` に追記されていること

## 解決方法

- 変更対象: `SoraTests/SignalingE2ETests.swift` に `testSendrecvDummyVideo` を追加（既存ヘルパーは変更しない）
- 2 チャンネルの getStats は非同期コールバックで返るため、1 試行内で両方のコールバック完了を待ち合わせる（カウンタ方式等）
- DummyVideoCapturer の `stop()` は切断の前に行う（`Timer.invalidate` はスレッドセーフなため、コールバックスレッドから呼んでも安全）
- inbound-rtp はチャンネル全体の受信統計であり、「相手からの映像」であることを厳密には検証できない（同一チャンネルへの第三者混入で誤検知し得る）。一意な channelId で混入リスクを軽減し、この限界を許容する
