# E2E テストと TSan テストの並行実行で同じチャンネル ID を共有し、片方の接続がタイムアウトする問題を修正する

- Created: 2026-10-09
- Completed: {YYYY-MM-DD}
- Branch: feature/fix-e2e-parallel-channel-id-collision
- Polished: {YYYY-MM-DD}

## 目的

E2E テストの CI が、同じ workflow run の `e2e` job と `tsan` job の並行実行で断続的に失敗する問題を解消する。実 Sora への接続が片方だけ `TIMEOUT` で終端するため、無関係な変更の PR でも E2E が赤くなる。

## 現状

- `.github/workflows/e2e-test.yml` の `e2e` job と `tsan` job は同じ runner ラベル (`self-hosted, macOS, ARM64, Apple-M1`) を使い、`tsan` に `needs` が無いため同じ run で並行実行される。2026-10-09 の run 37911069900 では runner `macos-m1` (machine `shiguredonoMac-mini`) と runner `macos-m1-2` (machine `shiguredono-mac-mini-m1-2`) で同時に開始した。別 machine のため、実行資源の競合ではない。
- 両 job の `env` は `TEST_CHANNEL_ID_SUFFIX: _${{ github.run_id }}` を共有する。`SoraTests/E2ETestBase.swift` の `buildChannelId(unique:)` は `unique: false` のとき `<prefix>e2e-test<suffix>` という固定のチャンネル ID を返し、`E2ETestBase.buildConfiguration()` は `unique: false` を使う。したがって同じ run の両 job が同じチャンネル ID へ同時に接続する。`unique: true` はテストが明示的に使う場合だけ有効で、21 箇所で使われている。
- run 37911069900 の `e2e` job は 1 件だけ失敗した。`SendonlyE2ETests.testSendonlyDummyAudio` が `webSocketClosed(statusCode: other(4490), reason: "TIMEOUT")` で終端している。同じ時刻 (09:26:47.18 と 09:26:47.24) に `tsan` job では同じテストが成功しており、`tsan` job は 521 件 / 7 skip / 失敗 0 で success している。
- 原因は同一チャンネル ID への同時接続と推定する。相関は上記の実測で確認できるが、Sora サーバー側のログは未確認である。
- 参考: 2026-10-06 の run 37423437932 (`StatisticsSnapshotE2ETests.testGetStatsSnapshotReturnsReadableValues` が失敗) は `tsan` job が無い run で、本件とは別の要因である。
- 参考: 失敗した run の `e2e` job の「E2E Crash Diagnostics」が出す `.ips` には、並行実行された `tsan` job の xctest プロセスの終了時 (`libclang_rt.tsan_iossim_dynamic.dylib` の `__tsan::finalize` → abort) の report が混ざる。今回の失敗は crash ではない (本 issue の対象外)。

## 設計方針

- 同じ run の `e2e` job と `tsan` job が同じチャンネル ID を使わないようにする。`.github/workflows/e2e-test.yml` の両 job の `TEST_CHANNEL_ID_SUFFIX` へ job 名を足す (例: `_${{ github.run_id }}_${{ github.job }}`)。run ごとの分離は維持したまま job ごとの分離を足す。
- `tsan` job へ `needs: e2e` を付ける直列化は採らない。両 job は別 machine の runner で並行実行できており、直列化は実行時間を増やすだけで、原因であるチャンネル ID の衝突を解消しない。
- `buildChannelId(unique:)` の既定を `unique: true` に変える案は採らない。チャンネル ID の固定に依存するテストがあるかを本 issue で判定できないため、CI の環境変数側で job ごとに分離する。
- チャンネル ID は接続先の識別にだけ使い、値そのものを検証するテストは無い。suffix の形式変更はテストの検証内容に影響しない。

## 完了条件

- 同じ run の `e2e` job と `tsan` job で `TEST_CHANNEL_ID_SUFFIX` が異なること (workflow の `env` と job log の env で確認できる)。
- `e2e` と `tsan` の両 job が success すること (再実行を含めて複数回確認する)。
- 失敗していた `SendonlyE2ETests.testSendonlyDummyAudio` が両 job で成功すること。
- SDK の実装・公開 API・テストの検証内容を変えないこと。

## 解決方法
