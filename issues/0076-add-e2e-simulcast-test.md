# Simulcast E2E テストを追加する

- Priority: Medium
- Created: 2026-07-10
- Completed:
- Model: GPT-5
- Branch: feature/add-e2e-simulcast-test
- Polished: 2026-08-13

## 目的

サイマルキャスト（simulcast）の E2E テストを追加する。JS SDK の `e2e-tests/tests/simulcast.test.ts` 相当の検証を行う。

## 現状

既存の iOS E2E テストに simulcast のテストが存在しない。

## 設計方針

sendonly 1 台 + recvonly 3 台（r0 / r1 / r2）の組み合わせで simulcast をテストする。4 つの `MediaChannel` を同一 `Sora()` インスタンスから直列に接続する（0075 の sendrecv テストと同じ構成）。

JS SDK の `simulcast.test.ts` も recvonly を r0 / r1 / r2 の 3 台接続している。recvonly は各レイヤー（r0 / r1 / r2）に購読者を 1 台ずつ配置する必要がある。購読者のいないレイヤーは Sora サーバーがエンコードを維持しない可能性があるためである。`getStats` による検証は sendonly 側のみ（codec stats（video/VP8）の存在と、outbound-rtp を rid ごとに `bytesSent` / `packetsSent` > 0、`scalabilityMode == "L1T1"` を確認）とし、iOS では加えて各 recvonly の inbound-rtp で受信量も確認する。

テストの流れ:

1. テスト固有の一意なチャンネル ID を生成し、全チャンネルで使用する（`buildChannelId(unique: true)`。`TEST_CHANNEL_ID_PREFIX` / `TEST_CHANNEL_ID_SUFFIX` 環境変数を組み合わせる。残留接続との混在を防ぐ）
2. sendonly を接続する（`role: .sendonly`、`simulcastEnabled: true`、`videoEnabled: true`、`audioEnabled: false`、`videoCodec: .vp8`、`videoBitRate: 1200`、`initialCameraEnabled: false`）。`videoBitRate` は明示指定する（simulcast では帯域制御がレイヤーごとにビットレートを割り当てるため、無指定だと高解像度レイヤー (r2) に 0 が割り当てられエンコードされない。Sora ドキュメントの simulcast の「映像ビットレート」セクション（960x540 で 3 ストリームに必要な 1200 kbps）に従う）。connect コールバックは実行キューが固定されていないため、共有状態の更新と後続処理は main queue に束ねる（`E2ETests` は @MainActor）
3. sendonly の connect コールバック内で `channel.senderStream` を取得して DummyVideoCapturer（960×540 @ 15fps）を設定・開始し、そのまま recvonly を r0 → r1 → r2 の順で接続する（`role: .recvonly`、`simulcastEnabled: true`、`simulcastRequestRid: .r0` / `.r1` / `.r2`、`videoEnabled: true`、`audioEnabled: false`、`videoCodec: .vp8`）。送信元解像度は r2（スケールダウンなし）の解像度になるため、js-sdk と同じ 960×540 にする。recvonly は送信しないため senderStream の guard は行わない。生成した capturer はテストメソッドスコープの変数に保持する（保持しないとコールバック終了時に解放され、フレーム送信が止まる）。接続した `MediaChannel` も同様に保持する
4. 接続完了を待つ（各 35 秒の `wait(for:timeout:)` で直列に実行する。ConnectionTimer が `Configuration.connectionTimeout` の 30 秒で発火するため、その発火を wait 内で処理する）。接続失敗時は、起動済みの capturer を stop して接続済みのチャンネルを切断し（切断完了まで待つ）、後続ステップをスキップして早期終了する。未接続の recvonly の expectation が未 fulfill のまま残るため、テスト終了時の unwaited expectation 報告を防ぐために fulfill する
5. 5 秒待機する（全チャンネルの接続完了後からカウントする）。待機は main RunLoop 上の `Timer` で行い、`Thread.sleep` は使用しない（main RunLoop を止めると DummyVideoCapturer のフレーム送信が停止するため）
6. 全チャンネルの `getStats` を取得する。sendonly 側は codec stats（video/VP8）の存在と、outbound-rtp を rid（r0 / r1 / r2）ごとに `bytesSent` / `packetsSent` が 0 より大きいことを確認する（3 レイヤー送信の確認）。recvonly 側は各チャンネルの inbound video stats の `bytesReceived` / `packetsReceived` が 0 より大きいことを確認する（各レイヤーの受信確認）。既存の `verifyVideoStats` は「両チャンネルの inbound-rtp」を前提とし、`verifyVideoCodecAndOutbound` は outbound-rtp を 1 つしか取得しないため、いずれも流用できない。既存の `verifyVideoStats` と同じカウンタ方式（検証対象ごとの getStats 完了を待ち合わせる）で、sendonly の outbound 検証と recvonly の inbound 検証を 1 つのリトライループで行う専用ヘルパーを新規に追加する。`scalabilityMode == "L1T1"`（js-sdk 相当）は確認対象に含める（libwebrtc m150 の outbound-rtp に含まれることを想定する）
7. stats 検証の成否に関わらず、DummyVideoCapturer の稼働（`isRunning` / `frameCount > 0`）を確認してから capturer を停止し、全チャンネルを切断する（`onDisconnect` で正常切断コード（1000）を確認。切断済みチャンネルでは onDisconnect が発火しないため、切断前に `state.isDisconnected` をチェックする）

映像の受信は送信側エンコーダが最初の keyframe を送出するまで受信パケットが存在しない。そのため、sendonly 側の outbound 検証（rid ごと）と recvonly 側の inbound 検証のすべてが確認できない場合は 5 秒間隔で再試行する（初回を含めて最大 5 回試行。keyframe の送出間隔が 10 秒超に伸びる可能性があるため、試行窓は 25 秒まで広げる）。5 秒待機と stats リトライは 1 つの expectation に統合し、その `wait(for:timeout:)` は 30 秒とする。codec stats と scalabilityMode の検証は、リトライが成功した場合のみ一度だけ行う。

`getStats` が `failure` を返した場合（接続済みでない場合等）は、接続状態の遷移（切断・チャンネル再生成等）が原因で発生し得るためリトライ対象とする。上限に達した場合は `XCTFail` し、診断メッセージに失敗理由と最後に観測した送受信量を含める。stats 検証が失敗しても後始末（capturer の稼働確認・停止、接続済みチャンネルの切断と正常切断コードの確認）はスキップせず実行し、残留チャンネルを残さない。

inbound-rtp には rid フィールドが存在しない（libwebrtc m150 の stats 仕様）ため、「どのレイヤーを受信したか」を recvonly 側の stats で直接確認することはできない。ただし、各レイヤー（r0 / r1 / r2）を購読する recvonly を 1 台ずつ接続し、それぞれの inbound-rtp で受信量を確認することで、レイヤーごとの受信を間接的に担保する。3 レイヤーの送信確認は sendonly 側の outbound-rtp（rid ごと）で行う。

同一プロセス内で 4 チャンネルを接続するため、`WrapperVideoEncoderFactory.shared.simulcastEnabled`（static shared）の共有状態に注意する。全チャンネルとも `simulcastEnabled: true` で統一する（ステップ 3 の直列接続により、sendonly が先に接続され、その後 recvonly が接続される）。

JS SDK の実装を参考にする: `e2e-tests/tests/simulcast.test.ts`

## テスト方針

- モック・スタブは使用しない
- `E2ETests` に `testSimulcastDummyVideo` として追加（Simulator での CI 実行を前提。`.github/workflows/ci.yml` の `e2e` ジョブ）
- 環境変数 `SORA_SIGNALING_URL` / `TEST_SECRET_KEY` が未設定の場合は、既存ヘルパー（`buildConfiguration`）の XCTSkip に委譲する
- `audioEnabled = false` のため、マイク権限は不要
- `initialCameraEnabled = false` を設定し、物理カメラの自動起動を抑止する（既存テストと同じ）
- `videoCodec = .vp8` を明示指定する（Simulator では H.264 エンコードが利用できない可能性があるため）
- `simulcastRequestRid` は非推奨の `simulcastRid` ではなく現行 API を使用する（Sora 2025.2.0 以降）
- タイムアウト: 接続 35 秒 × 4 台 + 待機・stats リトライ 30 秒 + 切断 10 秒 × 4 台で、全体を 210 秒以内に収める
- DummyVideoCapturer は 1 台だが、simulcast では 3 レイヤーを同時エンコードするため Simulator では CPU 負荷が高い。frameRate は 15 に下げる（30fps では高解像度レイヤー (r2) のエンコードが維持されず、`r2` の `bytesSent` が 0 のままになる事象を確認済み）

## Sora サーバー要件

- simulcast（`simulcast: true`）をサポートし、offer SDP に 3 レイヤー（r0 / r1 / r2）の simulcast 属性を含め、`encodings` 配列と対応させること（3 レイヤーの成立は offer SDP の simulcast 属性に依存し、SDK 側では encodings の追加は行われない）
- 購読者がいるレイヤーのエンコードを維持すること（recvonly 1 台で r0 のみを購読する構成では r2 の `bytesSent` が 0 のままになる事象を確認済み。各レイヤーに購読者を配置する構成で解決を試みる）
- VP8 の simulcast をサポートしていること
- `simulcastRequestRid` をサポートしていること（Sora 2025.2.0 以降）
- 同一チャンネルへの sendonly / recvonly の同時 4 接続を受け付けること
- 音声トラックなし（`audioEnabled = false`）の接続を受け付けること
- `metadata.access_token` による認証を受け入れること（0071 と同じ）
- `e2e-test` を含む channelId を拒否しないこと

## 完了条件

- `testSimulcastDummyVideo` が実装され、設計方針のテストの流れの全ステップを満たすこと
- `CHANGES.md` の develop セクションの `### misc` に追記されていること

## 解決方法
