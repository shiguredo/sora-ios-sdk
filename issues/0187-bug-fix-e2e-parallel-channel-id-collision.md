# E2E テストと TSan テストの並行実行で同じチャンネル ID を共有し、片方の接続がタイムアウトする問題を修正する

- Created: 2026-10-09
- Completed: {YYYY-MM-DD}
- Branch: feature/fix-e2e-parallel-channel-id-collision
- Polished: 2026-10-09

## 目的

E2E テストの CI が、同じ workflow run の `e2e` job と `tsan` job の並行実行で断続的に失敗する問題を解消する。実 Sora への接続が片方だけ `TIMEOUT` で終端するため、無関係な変更の PR でも E2E が赤くなる。

## 現状

- `.github/workflows/e2e-test.yml` の `e2e` job と `tsan` job は同じ runner ラベル (`self-hosted, macOS, ARM64, Apple-M1`) を使い、`tsan` に `needs` が無いため同じ run で並行実行される。2026-10-09 の run 37911069900 では runner `macos-m1` (machine `shiguredonoMac-mini`) と runner `macos-m1-2` (machine `shiguredono-mac-mini-m1-2`) で同時に開始した。別 machine のため、実行資源の競合ではない。
- 両 job の `env` は `TEST_CHANNEL_ID_SUFFIX: _${{ github.run_id }}` を共有する。`SoraTests/E2ETestBase.swift` の `buildChannelId(unique:)` は `unique: false` のとき `<prefix>e2e-test<suffix>` という固定のチャンネル ID を返し、`E2ETestBase.buildConfiguration()` は `unique: false` を使う。したがって同じ run の両 job が同じチャンネル ID へ同時に接続する。`unique: true` はテストが明示的に使う場合だけ有効で、21 箇所で使われている。
- run 37911069900 の attempt 1 (`e2e` job と `tsan` job がいずれも 09:24:34 に開始) では、`e2e` job が 1 件だけ失敗した。`SendonlyE2ETests.testSendonlyDummyAudio` が `webSocketClosed(statusCode: other(4490), reason: "TIMEOUT")` で終端している。同じ時刻 (09:26:47.18 と 09:26:47.24) に `tsan` job では同じテストが成功しており、`tsan` job は 521 件 / 7 skip / 失敗 0 で success している。attempt 3 の `e2e` job も 521 件 / 7 skip / 失敗 0 で success している。
- attempt 2 の `e2e` job も失敗しているが、失敗は `PeerChannelMessagingRaceTests.testSendMessageAfterRedirectInvalidationDoesNotReachOldDataChannel` の実行中に起きた xctest の crash (`EXC_BAD_ACCESS` / `SIGSEGV`) であり、本件とは別の要因である (attempt 2 では `tsan` job は再実行されていない)。
- 原因は同一チャンネル ID への同時接続と推定する。相関は上記の実測で確認できるが、Sora サーバー側のログは未確認であり、推定の域を出ない。修正後も同じ現象が再発する可能性は残るため、再発した場合は本 issue を reopened にして Sora サーバー側のログを確認する。
- 参考: 2026-10-06 の run 37423437932 では、`e2e` job と `tsan` job が同じ時刻 (06:23:18) に開始し、両方の job で `StatisticsSnapshotE2ETests.testGetStatsSnapshotReturnsReadableValues` が失敗した (`tsan` は 492 件中 1 件で、このテストが 90.1 秒で終端している)。`tsan` job は存在しており、失敗したテストが本件と異なるため、原因は断定せず本 issue の対象外とする。
- 参考: 失敗した run の `e2e` job の「E2E Crash Diagnostics」は、`libclang_rt.tsan_iossim_dynamic.dylib` の `__tsan::finalize` → abort で終了した xctest の report を出す (run 37911069900 の attempt 1 で 1 件)。これは今回の失敗 (テストの assertion 失敗) とは別の report であり、本 issue の対象外とする。

## 設計方針

- 同じ run の `e2e` job と `tsan` job が同じチャンネル ID を使わないようにする。`.github/workflows/e2e-test.yml` の両 job の `TEST_CHANNEL_ID_SUFFIX` へ job 名を足す (`e2e` job は `_${{ github.run_id }}_e2e`、`tsan` job は `_${{ github.run_id }}_tsan`)。run ごとの分離は維持したまま job ごとの分離を足す。
- job 名は各 job の `env` へ直接書く。job 名の部分が固定値になるため、workflow の `env` 定義を読むだけで job ごとに異なる suffix であることが確認でき、job log の env でも照合できる。`TEST_CHANNEL_ID_SUFFIX` を使う job を増やす場合は、同じ run の job 間で値が重複しないよう job 名の部分を足す。
- `tsan` job へ `needs: e2e` を付ければ両 job が同時に接続しなくなり、観測された衝突は起きなくなる。しかし両 job は別 machine の runner で並行実行できており、直列化は実行時間を約 3 分増やす (実測: `e2e` は約 3 分 28 秒、`tsan` は約 3 分 15 秒)。チャンネル ID を job ごとに分離すれば並行実行のまま衝突を解消できるため、直列化は採らない。
- `buildChannelId(unique:)` の既定を `unique: true` に変える案は採らない。チャンネル ID の固定に依存するテストがあるかを本 issue で判定できないため、CI の環境変数側で job ごとに分離する。
- チャンネル ID は接続先の識別にだけ使い、値そのものを検証するテストは無い。suffix の形式変更はテストの検証内容に影響しない。

## 完了条件

- 同じ run の `e2e` job と `tsan` job で `TEST_CHANNEL_ID_SUFFIX` が異なること (workflow の `env` と job log の env で確認できる)。
- 同じ run の `e2e` job と `tsan` job が同じチャンネル ID へ接続しないこと。両 job のログに `webSocketClosed(statusCode: other(4490), reason: "TIMEOUT")` が出ないことをもって確認する。
- `e2e` と `tsan` の両 job が success する run を、両 job が並行実行される状態で 5 回以上確認する (再実行を含む)。Sora サーバー側のエラー (`NSURLErrorDomain Code=-1011` / `Code=-1004` など)、xctest の crash、本 issue が対象としない他のテスト失敗で赤くなった run は検証回数に数えず、原因を別 issue として記録したうえで再実行する。
- 失敗していた `SendonlyE2ETests.testSendonlyDummyAudio` が両 job で成功すること。
- SDK の実装・公開 API・テストの検証内容を変えないこと。
- `CHANGES.md` の `## develop` の `### misc` に `- [FIX]` のエントリを追記する (`- @t-miya` 行付き)。

## 解決方法
