# reconnect E2E テストを追加する

- Priority: Medium
- Created: 2026-07-10
- Completed:
- Model: GPT-5
- Branch: feature/add-e2e-reconnect-test
- Polished: 2026-08-13

## 目的

Sora サーバー起点の切断からの再接続を検証する E2E テストを追加する。JS SDK の `e2e-tests/tests/reconnect.test.ts` 相当の検証を行う。

## 現状

既存の iOS E2E テストに再接続のテストが存在しない。

## 設計方針

sendonly で接続後、Sora API（DisconnectConnection）でサーバー側から切断し、クライアントが再接続することを確認する。

iOS SDK に自動再接続機能は存在しない（`MediaChannel` は再利用不可。MediaChannel.swift の「一度接続を行ったメディアチャネルは再利用できません」の記述を参照）。js-sdk も再接続は SDK 機能ではなくテストページ側の実装（`onDisconnect` 検知 → 新しい接続を作り直す）であるため、iOS でもテストコード側が `onDisconnect` を検知して、同じ channelId で `sora?.connect(configuration:)` を再呼び出しして新規 `MediaChannel` を接続する。

テストの流れ:

1. テスト固有の一意なチャンネル ID を生成する（`buildChannelId(unique: true)`。Sora API は `channel_id` を指定するため、他テストのチャンネルを誤って切断しないよう一意化が必須）
2. sendonly を接続する（`role: .sendonly`、`videoEnabled: true`、`audioEnabled: false`、`videoCodec: .vp8`、`initialCameraEnabled: false`、DummyVideoCapturer 640×480 @ 30fps）。`buildConfiguration(role:)` が生成する `channelId`（非一意な `e2e-test`）を、手順 1 の一意な値に上書きする（0075 と同じパターン）。connect コールバックは実行キューが固定されていないため、共有状態の更新と後続処理は main queue に束ねる（`E2ETestBase` は @MainActor）。js-sdk は接続後のレース対策として 3 秒待機しているが、iOS の connect コールバックはシグナリング完了 + ICE 接続確立後に発火するため待機は不要とする
3. 接続完了後に初回の `MediaChannel.connectionId` を保存し、`onDisconnect` ハンドラを設定する（切断理由の確認と切断検知 expectation の fulfill のみを行う。再接続はテスト本体で実行する）
4. Sora API（DisconnectConnection）でサーバー側から切断する
   - `POST {TEST_API_URL}`、ヘッダ `X-Sora-Target: Sora_20151104.DisconnectConnection`、ボディ `{"channel_id": ..., "connection_id": ...}`、タイムアウト 10 秒（js-sdk と同様）
   - `connection_id` は `MediaChannel.connectionId` から取得する
   - レスポンスの HTTP 2xx を確認する（js-sdk は `response.ok` のみ確認）。非 2xx・タイムアウト・到達不能の場合は `XCTFail` して切断検知を待たずに後始末へ進む。このとき未 fulfill の切断検知 expectation を fulfill して、テスト終了時の unwaited expectation 報告を防ぐ
5. `onDisconnect` が発火し（wait 10 秒）、切断理由（`SoraCloseEvent`）を確認する（Sora API 切断では code 1000 / reason "DISCONNECTED-API" が期待される。サーバー実装依存のため、実装時に実測して確定する）
6. 切断検知後、1 秒待機してから（即時再接続による DUPLICATED-CHANNEL-ID レースを避けるため）、テスト本体で同じ channelId の新 Configuration を使い `sora?.connect(configuration:)` を再呼び出しして再接続する。1 秒の待機は main RunLoop 上の `Timer` または `asyncAfter` で行い、`Thread.sleep` は使用しない（main RunLoop を止めると DummyVideoCapturer のフレーム送信が停止するため）。再接続時は DummyVideoCapturer を新しい `senderStream` に付け替える（既存 capturer を再利用し、`stop()` → `stream` 差し替え → `start()`。js-sdk は保存した MediaStream を再利用する）。再接続に失敗した場合は `XCTFail` して後始末へ進む
7. 再接続の成功を確認する（新しい `MediaChannel.connectionId` が初回と異なること。js-sdk のテストと同様。capturer の付け替え結果の検証は行わない）
8. 後始末: capturer を停止し、接続済みチャンネル（再接続後の新チャンネル）を切断する（`disconnectAndVerify`）。旧チャンネルはサーバー切断時に `Sora.remove` で `mediaChannels` から除去され `state == .disconnected` になるため、`disconnectAndVerify` の state チェックでスキップされる（後始末の対象外）。再接続失敗時も後始末はスキップしない

Sora API への到達性:

- 環境変数 `TEST_API_URL`（Sora API のエンドポイント URL）を新設する。未設定の場合は XCTSkip でスキップする
- CI の e2e ジョブへの `TEST_API_URL` の注入は、実装時に self-hosted ランナーからの到達性を確認してから行う（js-sdk は Tailscale が利用できない self-hosted では実行しない方針のため、iOS CI の self-hosted ランナーから Sora API へ到達できるかの確認が必要）

JS SDK の実装を参考にする: `e2e-tests/tests/reconnect.test.ts`

## テスト方針

- モック・スタブは使用しない
- `SendonlyE2ETests` に `testSendonlyReconnect` として追加（Simulator での CI 実行を前提。`.github/workflows/ci.yml` の `e2e` ジョブ）
- 環境変数 `SORA_SIGNALING_URL` / `TEST_SECRET_KEY` が未設定の場合は、既存ヘルパー（`buildConfiguration`）の XCTSkip に委譲する
- `TEST_API_URL` が未設定の場合は XCTSkip でスキップする
- `audioEnabled = false` のため、マイク権限は不要
- `initialCameraEnabled = false` を設定し、物理カメラの自動起動を抑止する（既存テストと同じ）
- タイムアウト: 初回接続 35 秒 + Sora API 10 秒 + 切断検知 10 秒 + 再接続 35 秒 + 後始末切断 10 秒で、全体を 100 秒以内に収める

## Sora サーバー要件

- DisconnectConnection API が有効であること
- 同一 channelId への切断後の再接続を受け付けること（即時再接続時の DUPLICATED-CHANNEL-ID レースが発生しないこと）
- `metadata.access_token` による認証を受け入れること（0071 と同じ）
- `e2e-test` を含む channelId を拒否しないこと

## 完了条件

- サーバー側切断後に再接続できること
- 再接続後の `connectionId` が初回と異なること
- CI の e2e ジョブへの `TEST_API_URL` の注入（または注入をスコープ外とする判断）が完了していること
- `CHANGES.md` の develop セクションの `### misc` に追記されていること

## 解決方法
