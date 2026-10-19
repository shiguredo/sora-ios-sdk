# PeerChannelMessagingRaceTests の xctest クラッシュで e2e job が失敗する問題を修正する

- Created: 2026-10-16
- Completed: 2026-10-19
- Branch: feature/fix-e2e-messaging-race-crash
- Polished: 2026-10-16

## 目的

E2E テストの CI が、テストのアサーション失敗ではなく xctest のクラッシュで失敗する問題を解消する。develop の `e2e` job が赤くなる原因として残っている。

## 現状

2026-10-16 の develop への push (run 38872361304、sha 47e9d26e) の `e2e` job (job id 116879209067) が失敗した。job log から確認できた事実は次のとおり。

- テストのアサーション失敗は 0 件である。`xcodebuild` が最後に出す "Failing tests" は `PeerChannelMessagingRaceTests.testSendMessageAndRedirectInvalidationRace()` を指している。
- job log は 08:16:04 に同テストの `started` を出したあと、08:16:13 に `Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.` を出してテストセッションをやり直している。同テストの `passed` / `failed` は出ていない。
- クラッシュのあと、xcodebuild は 08:16:13 に `Selected tests` セッションでテストを再開している。`Executed 277 tests, with 1 test skipped and 0 failures` はこの再開セッションの集計である。クラッシュ前のセッションは 245 件を実行し (238 passed / 6 skipped)、再開セッションが 277 件を実行したため、合計 522 件 (514 passed / 7 skipped / failed 0) で全件が実行されている。結果を残せなかったのはクラッシュした当該テスト 1 件だけである。同じコードで成功した run 38866197947 の attempt 5 も 522 tests / 7 skipped / 0 failures で、実行数は健全時と一致する。
- `Show E2E Crash Diagnostics` step は xctest の report を 4 件出力した。このうち 3 件は `EXC_BAD_ACCESS` / `SIGSEGV` で、faulting thread の先頭フレームはいずれも `webrtc::Thread::Get(int)` → `webrtc::Thread::ProcessMessages(int)` → `webrtc::Thread::PreRun(void*)` → `_pthread_start` → `thread_start` であり、WebRTC が生成したスレッドがメッセージを処理している最中のクラッシュである。残り 1 件は `EXC_CRASH` / `SIGABRT` (`Abort trap: 6`) で、フレームに `libclang_rt.tsan_iossim_dynamic.dylib` の `__sanitizer::Abort()` → `__tsan::finalize(void*)` を含む。`e2e` job は `-enableThreadSanitizer` を渡しておらず (`.github/workflows/e2e-test.yml` で有効なのは `tsan` job だけ)、TSan で計装した別の実行に由来する report が混ざったものと考えられる (issue 0187 の現状にも同種の report を別物として扱う記録がある)。また step の出力には report の採取時刻が無く、`Restarting` も 1 回だけであるため、3 件の `EXC_BAD_ACCESS` がすべてこの再開に由来するものかまでは特定できていない。
- 同じ run の `tsan` job は success である。`RpcE2ETests.testRPCRaceWithDisconnectTerminatesAll` は同 run の `e2e` job で passed (5.002 秒) しており、issue 0190 が対象にした失敗ではない。
- 同じクラッシュはこれまでも記録されている。issue 0187 の現状には `PeerChannelMessagingRaceTests.testSendMessageAfterRedirectInvalidationDoesNotReachOldDataChannel` の実行中に起きた xctest の crash (`EXC_BAD_ACCESS` / `SIGSEGV`) が別要因として記録され、issue 0190 の現状には run 38833224522 の `Show E2E Crash Diagnostics` step が同じ `webrtc::Thread::Get` の report を出したことが、本筋とは別の report として記録されている。どちらも issue 化されないまま残っており、今回も同じクラッシュで `e2e` job が赤くなった。
- `SoraTests/PeerChannelMessagingRaceTests.swift` の `testSendMessageAndRedirectInvalidationRace` は 0135 で追加された concurrency runtime stress test である。実 `MediaChannel` / 実 `PeerChannel` / 実 `RTCPeerConnection` / 実 `RTCDataChannel` を生成し (`RPCChannel` を使うのは同じファイルの RPC 系テスト)、`DispatchQueue.concurrentPerform` で `sendMessage` と redirect の無効化を交差させる (`rounds` 8、`concurrentWorkers` 4、`operationsPerWorker` 200)。`tearDown` で生成した DataChannel と PeerConnection を解放する。実 Sora へは接続しないテストのため、ローカルの Simulator でも実行できる。このクラスのテストは `e2e` job と `tsan` job の両方で実行される。
- クラッシュがテスト本体 (交差区間) で起きているのか、`tearDown` の解放で起きているのかは特定できていない。同じクラスの中でクラッシュしたテストが 2 件 (`testSendMessageAndRedirectInvalidationRace` / `testSendMessageAfterRedirectInvalidationDoesNotReachOldDataChannel`) あるため、特定のテスト固有ではなく、このクラスのテストが作る WebRTC オブジェクトの解放に共通する要因の可能性がある。

## 設計方針

- まず再現条件を絞り込む。`PeerChannelMessagingRaceTests` は実 Sora へ接続しないため、Simulator で同テストを繰り返し実行し、どの操作 (交差区間、`tearDown` の解放、生成と解放の順序、同時に生存するオブジェクトの数) でクラッシュするのかを特定する。
- 原因がテスト側の後始末 (WebRTC オブジェクトの解放順・解放タイミング) にある場合はテストを修正する。SDK 側の解放経路にある場合は SDK を修正するが、公開 API は変えない。
- 反復回数や並行度を落としてクラッシュ確率を下げる対処はしない。0135 の検証内容 (実 WebRTC オブジェクトの交差を反復し、交差後に `sendMessage` が旧 DataChannel へ送信しないことを確認する) を弱めない。
- モックやスタブは利用しない。実 `MediaChannel` / 実 `PeerChannel` / 実 `RTCPeerConnection` / 実 `RTCDataChannel` を使う現状の方針を維持する。
- 原因が SDK / WebRTC 側にあり SDK から回避できないと判明した場合は、その事実と根拠を本 issue に記録し、`e2e` job の失敗条件を変えるかどうかは別途判断する (勝手に失敗条件を緩めない)。

## 完了条件

- クラッシュの再現条件と原因 (テスト側 / SDK 側 / WebRTC 側) が、実行して得た根拠つきで本 issue に記録されていること。再現しなかった場合は、試した条件とその結果を記録したうえで、原因の推定と対応方針を示していること。
- 原因に応じた対応が完了していること。テスト側ならテストの修正、SDK 側なら SDK の修正 (公開 API は変えない)。原因が SDK / WebRTC 側にあり SDK から回避できないと判明した場合は、その事実と根拠を本 issue に記録したうえで、`e2e` job の失敗条件の扱いをユーザーの判断で確定し、その結論を本 issue に反映していること (勝手に失敗条件を緩めない)。
- `e2e` job を 5 回以上 success させること (再実行を含めてよい)。本件のクラッシュで失敗した run は原因を記録したうえで再実行し、成功した回だけを数える。このクラスのテストは `tsan` job でも実行されるため、`tsan` job でも同じクラッシュが再現しないことを確認すること。
- テストの検証内容を弱めていないこと。
- 変更後に `SoraTests` が Simulator で失敗 0 であること。

## 解決方法

2026-10-19 に対応する。クラッシュの直接の再現と原因の確定には至らなかったが、テスト側の後始末の不備を解消し、E2E の crash 診断をテスト実行中の report に限定した。SDK の実装・公開 API は変更していない。

### 調査結果

- 失敗した run 38872361304 (sha 47e9d26e) の crash report のうち 3 件は `EXC_BAD_ACCESS` / `SIGSEGV` で、faulting thread の先頭フレームは `webrtc::Thread::Get` → `webrtc::Thread::ProcessMessages` → `webrtc::Thread::PreRun` → `_pthread_start` だった。WebRTC が生成したスレッドがメッセージを処理している最中のクラッシュである
- `PeerChannelMessagingRaceTests` は実 `MediaChannel` / 実 `PeerChannel` / 実 `RTCPeerConnection` / 実 `RTCDataChannel` を生成し、`DispatchQueue.concurrentPerform` で `sendMessage` と redirect の無効化を交差させる。修正前の `tearDown` は delegate を外して参照を落とすだけで、native の `RTCPeerConnection` / `RTCDataChannel` を `close()` していなかった
- SDK の `PeerChannel.disconnect` は `nativeChannel.close()` を呼んでから解放する。テストの後始末も同じ順序に揃える必要がある
- 以上から、原因はテスト側の後始末 (native の `RTCPeerConnection` / `RTCDataChannel` を close せずに解放したこと) と推定した。ただしクラッシュの再現と特定には至っていない
- クラッシュがテスト本体 (交差区間) で起きているのか `tearDown` の解放で起きているのかは特定できていない。同じクラスの `testSendMessageAfterRedirectInvalidationDoesNotReachOldDataChannel` でも同種の crash が記録されている
- 共有 runner の Simulator には過去の実行の crash report が残るため、`Show E2E Crash Diagnostics` が本件と無関係の report (TSan で計装した別実行の report を含む) を出力していたと考えられる

### 対応

- `SoraTests/PeerChannelMessagingRaceTests.swift` の `tearDown` を修正した
  - delegate を外した後に `RTCDataChannel.close()` を呼ぶ
  - その後に `RTCPeerConnection.close()` を呼ぶ
  - 最後に factory を保持する `MediaChannel` の参照を落とす
  - `hasStuckPath` が true の場合は、停止した排他区間を待たないため、close も含めて SDK の状態を触らない
- `.github/workflows/e2e-test.yml` の `Show E2E Crash Diagnostics` を修正した
  - result bundle の作成時刻をテスト実行の開始時刻とし、それより前に採取された `.ips` を除外する
  - 採取時刻には `captureTime` を使い、無い場合はヘッダの `timestamp` を使う。時刻を取得できない report は比較せず対象に残す (fail-open)
  - report 名・採取時刻・pid・`procLaunch`・`bugType`・faulting thread・main thread のフレームを出力する
  - 除外・時刻不明・対象・対象外プロセス・出力失敗の件数を集計して出力する
  - `Run E2E Tests` に `timeout-minutes: 30` を設定し、ハング時も診断 step が実行されるようにした
- `CHANGES.md` の `## develop` の `### misc` に `[FIX]` を 2 件追記した

### 検証

- 実 CI (2026-10-19、run 39190992604、sha `39510c7`) で `e2e` job を 5 回 success させた (attempt 1 は push による初回、attempt 2〜5 は job の再実行)
  - 各 attempt とも 522 tests / 7 skipped / 0 failures で、`Restarting after unexpected exit, crash, or test timeout` は 0 件
  - `PeerChannelMessagingRaceTests` は 5 回とも 8 件すべて pass。クラッシュが記録されていた `testSendMessageAndRedirectInvalidationRace` と `testSendMessageAfterRedirectInvalidationDoesNotReachOldDataChannel` も 5 回とも pass した
- 同じ run の `tsan` job は attempt 1 で 522 tests / 7 skipped / 0 failures の success。同じクラスのテストも pass し、クラッシュは再現していない
- テストの検証内容 (rounds 8、concurrentWorkers 4、operationsPerWorker 200 の交差と、無効化後に旧 DataChannel へ送信しないことの確認) は変えていない
- `SoraTests` は Simulator で 0 failures

### 残った懸念

- クラッシュの再現条件と原因は確定できていない。今回の CI 5 回では再現しなかったが、5 回の success は「修正後に再発しないこと」の確認であり、原因を特定したものではない
- 次に同じクラスの crash が発生した場合は、修正した診断 step がテスト実行中の report だけを出力するため、`captureTime` と faulting thread からテスト本体か後始末かを判断できる
- `Show E2E Crash Diagnostics` は success 時には実行されないため、診断 step の変更は失敗 run でしか検証できない。今回は 5 回とも success だったため、診断 step 自体は実行されていない
