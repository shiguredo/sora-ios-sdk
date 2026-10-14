# tsan job が WebRTC の thread leak で不安定に失敗する問題を修正する

- Created: 2026-10-14
- Completed: {YYYY-MM-DD}
- Priority: Medium
- Branch: feature/fix-tsan-thread-leak
- Polished: 2026-10-14

## 目的

`e2e-test.yml` の tsan job が、WebRTC の xcframework が生成したスレッドの thread leak 報告で不安定に失敗するのを止める。データ競合を検出する gate としての役割は維持し、CI の失敗要因を減らす。

## 優先度根拠

tsan job は develop と PR のブランチへの push で走る (`on` は `push` と `workflow_dispatch` で、`pull_request` は無い) ため、失敗すると run が赤くなり、その run の切り分けに時間を取られる。直近 40 run のうち tsan job が実行された 35 run では 5 件が失敗しており (約 14%)、そのうち thread leak の報告を含むのは本件の 1 件である。データ競合の検出は維持する必要があるため、gate 全体を無効化するのではなく TSan のオプションで対象を限定する。

## 現状

- run 38511195252 (2026-10-14、develop、`0182` の PR `#429` のマージ後、https://github.com/shiguredo/sora-ios-sdk/actions/runs/38511195252) の tsan job は `Executed 521 tests, with 7 tests skipped and 0 failures` で全件成功し、データ競合も 0 件だった。その直後に `WARNING: ThreadSanitizer: thread leak` を報告し、`ThreadSanitizer: reported 1 warnings` の後に `Child process terminated with signal 6: Abort trap` で TSan が abort した (この abort により `tsan_exit_code` は 134 になる)。この run の `Run Thread Sanitizer Tests` step の失敗理由は、同じ step で起きた report 抽出の失敗 (`0189`) による exit 2 であり、`Check Thread Sanitizer Report` step は skipped になっている。抽出が成功していても report 1 件と exit code 134 の判定で `Check Thread Sanitizer Report` step は失敗するため、thread leak は job の失敗要因である。
- report のスタックは `pthread_create` → `WebRTC:arm64+...` → `RTCPeerConnectionFactory.__allocating_init` → `NativePeerChannelFactory.init` → `MediaChannel.init` → `makeTestMediaChannel()` → `PeerChannelMessagingRaceTests.testSendMessageAfterRedirectInvalidationDoesNotReachOldDataChannel` である。leak 元は WebRTC の xcframework が `RTCPeerConnectionFactory` の生成時に作ったスレッドで、report は既に終了した未 join の pthread に対する報告である。
- `.github/workflows/e2e-test.yml` の tsan job は `SIMCTL_CHILD_TSAN_OPTIONS=verbosity=1` で TSan を動かす。`Run Thread Sanitizer Tests` step は `tsan_exit_code` と `tsan_report_count` を `GITHUB_ENV` へ渡すだけで成否を判定せず、判定は `Check Thread Sanitizer Report` step が行う。判定は `^WARNING: ThreadSanitizer` の行数 (report の件数)、`***** Running under ThreadSanitizer` の banner、`Executed N tests` の test 数、`tsan_exit_code` の 4 つで、`WARNING: ThreadSanitizer: thread leak` も行数に数える。そのため thread leak の報告でも job が失敗する。
- SDK と SoraTests は生スレッドを生成しない (`Sora/` は `Thread.isMainThread` のみで、`pthread_create` / `Thread(` / `Thread.detachNewThread` の利用は無い)。今回の leak は SDK 側から join できない WebRTC 内部のスレッドである。
- 同じ `0182` の作業でも先行の run 38508926978 は tsan job が成功しており、フレーキーである。直近 40 run の tsan job の失敗 5 件の内訳は次のとおりで、本件以外は thread leak ではない別の問題である。
  - 38511195252 (2026-10-14): thread leak (本件)。
  - 37915949613 (2026-10-09): report 0 件で、抽出が不正なバイト列により失敗した (`0189`)。
  - 38504592116 (2026-10-14): `RpcE2ETests.testRPCRaceWithDisconnectTerminatesAll` が `connectionTimeout` で失敗し、`tsan_exit_code` が非 0 になった。
  - 36848156662 (2026-10-01): attempt 1 は `0135` が扱う `rpcChannel` の競合、attempt 2 は `WrapperVideoEncoderFactory` の競合 (`0185` が修正した) が検出された。
  - 36670380572 (2026-09-30): `ConcurrencyStressE2ETests` の接続設定の誤りによる 4490 `INVALID-MESSAGE` で、`0119` が同じ PR で修正した。

## 設計方針

- tsan job の `SIMCTL_CHILD_TSAN_OPTIONS` に `report_thread_leaks=0` を追加する。これは TSan の公式ランタイムフラグ (`report_thread_leaks`、既定 true) で、スレッドリークの報告だけを止める。データ競合の検出条件は変えない。
- WebRTC の prebuilt モジュールが作る未 join スレッドは SDK 側で join できないため、これを job の失敗条件に含めない。この理由は workflow のコメントとして日本語で残す。
- 「report は残し、`data race` の行だけを失敗条件にする」代替案は採らない。thread leak を報告した TSan はプロセスを abort させるため exit code 134 を許容する分岐が必要になり、SDK が生スレッドを作らない現状では検出力の利得が無い。
- `Check Thread Sanitizer Report` step の 4 つの判定 (`^WARNING: ThreadSanitizer` の行数、`verbosity=1` の banner 検査、test 数検査、`tsan_exit_code` の検査) は変更しない。

## 変更対象

- `.github/workflows/e2e-test.yml`: tsan job の `Run Thread Sanitizer Tests` step の `SIMCTL_CHILD_TSAN_OPTIONS` に `report_thread_leaks=0` を追加し、WebRTC 内部のスレッドを失敗条件に含めない理由をコメントに書く。

## テスト方針

- self-hosted runner (macOS / Xcode 26.6 / iOS 26.5 simulator) で tsan job を実行し、thread leak が出る条件でも job が成功することを確認する。
- データ競合の検出条件が残っていることを、`Check Thread Sanitizer Report` step の 4 つの判定 (`^WARNING: ThreadSanitizer` の行数、`verbosity=1` の banner 検査、test 数検査、`tsan_exit_code` の検査) が workflow に残っていることで確認する。
- `TSAN_OPTIONS=help=1` の出力に `report_thread_leaks` が含まれることを確認する。

## 完了条件

- tsan job が WebRTC の thread leak で失敗しない。
- データ競合の検出条件 (`^WARNING: ThreadSanitizer` の行数と exit code) が維持されている。
- 直近で thread leak が出た run (38511195252) と同じ build と実行の条件で tsan job が成功する。この run は report 抽出の失敗 (`0189`) でも `Run Thread Sanitizer Tests` step が失敗しているため、確認は `0189` の修正後に行う。

## 前提となる issue

- `0119` (完了): tsan job を追加した。本件はその job の失敗条件の調整である。
- `0187` (完了): e2e job と tsan job のチャンネル ID 衝突を修正した。本件の失敗とは別である。
- `0135` (open): messaging 経路のデータ競合を扱う。本件はデータ競合ではなく thread leak であり、混同しない。
- `0189` (open): 同じ run 38511195252 で report 抽出が不正なバイト列により失敗し、`Run Thread Sanitizer Tests` step の失敗理由を上書きしていた。本件の完了条件 (thread leak が出た run と同じ条件で tsan job が成功すること) の確認は `0189` の修正を前提にする。両 issue は同じ `Run Thread Sanitizer Tests` step を変更する。

## スコープ外

- tsan job 内で走る E2E テストのサーバー接続 timeout のフレーキーは別問題とする。
- WebRTC の factory がプロセス終了まで生存する経路の追跡は本 issue では行わない。
- データ競合の検出条件そのものの見直しは行わない。

## 解決方法
