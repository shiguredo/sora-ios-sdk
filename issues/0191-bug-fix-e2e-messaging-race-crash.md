# PeerChannelMessagingRaceTests の xctest クラッシュで e2e job が失敗する問題を修正する

- Created: 2026-10-16
- Completed: {YYYY-MM-DD}
- Branch: feature/fix-e2e-messaging-race-crash
- Polished: {YYYY-MM-DD}

## 目的

E2E テストの CI が、テストのアサーション失敗ではなく xctest のクラッシュで失敗する問題を解消する。develop の `e2e` job が赤くなる原因として残っている。

## 現状

2026-10-16 の develop への push (run 38872361304、sha 47e9d26e) の `e2e` job (job id 116879209067) が失敗した。job log から確認できた事実は次のとおり。

- テストのアサーション失敗は 0 件である。`xcodebuild` が最後に出す "Failing tests" は `PeerChannelMessagingRaceTests.testSendMessageAndRedirectInvalidationRace()` を指している。
- job log は 08:16:04 に同テストの `started` を出したあと、08:16:13 に `Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.` を出してテストセッションをやり直している。同テストの `passed` / `failed` は出ていない。
- 実行数は 277 tests / 1 skipped である。同じコードで成功した run 38866197947 の attempt 5 は 522 tests / 7 skipped であり、クラッシュでセッションが途中終了して残りのテストが実行されていない。
- `Show E2E Crash Diagnostics` step は xctest の `EXC_BAD_ACCESS` / `SIGSEGV` の report を 4 件出力した。faulting thread の先頭フレームは 4 件とも `webrtc::Thread::Get(int)` → `webrtc::Thread::ProcessMessages(int)` → `webrtc::Thread::PreRun(void*)` → `_pthread_start` → `thread_start` で、WebRTC が生成したスレッドがメッセージを処理している最中のクラッシュである。
- 同じ run の `tsan` job は success である。`RpcE2ETests.testRPCRaceWithDisconnectTerminatesAll` は同 run の `e2e` job で passed (5.002 秒) しており、issue 0190 が対象にした失敗ではない。
- 同じクラッシュはこれまでも記録されている。issue 0187 の現状には `PeerChannelMessagingRaceTests.testSendMessageAfterRedirectInvalidationDoesNotReachOldDataChannel` の実行中に起きた xctest の crash (`EXC_BAD_ACCESS` / `SIGSEGV`) が別要因として記録され、issue 0190 の現状には run 38833224522 の `Show E2E Crash Diagnostics` step が同じ `webrtc::Thread::Get` の report を出したことが、本筋とは別の report として記録されている。どちらも issue 化されないまま残っており、今回も同じクラッシュで `e2e` job が赤くなった。
- `SoraTests/PeerChannelMessagingRaceTests.swift` の `testSendMessageAndRedirectInvalidationRace` は 0135 で追加された concurrency runtime stress test である。実 `MediaChannel` / 実 `PeerChannel` / 実 `RTCPeerConnection` / 実 `RTCDataChannel` / 実 `RPCChannel` を生成し、`DispatchQueue.concurrentPerform` で `sendMessage` と redirect の無効化を交差させる (`rounds` 8、`concurrentWorkers` 4、`operationsPerWorker` 200)。`tearDown` で生成した DataChannel と PeerConnection を解放する。実 Sora へは接続しないテストのため、ローカルの Simulator でも実行できる。
- クラッシュがテスト本体 (交差区間) で起きているのか、`tearDown` の解放で起きているのかは特定できていない。`webrtc::Thread::Get` は WebRTC のスレッドが自身の状態を読む箇所であり、SDK / WebRTC の解放経路とテストの後始末のどちらに原因があるかは切り分けが必要である。同じクラスの中でクラッシュしたテストが 2 件 (`testSendMessageAndRedirectInvalidationRace` / `testSendMessageAfterRedirectInvalidationDoesNotReachOldDataChannel`) あるため、特定のテスト固有ではなくこのクラスのテストが作る WebRTC オブジェクトの解放に共通する要因の可能性がある。

## 設計方針

- まず再現条件を絞り込む。`PeerChannelMessagingRaceTests` は実 Sora へ接続しないため、Simulator で同テストを繰り返し実行し、どの操作 (交差区間、`tearDown` の解放、生成と解放の順序、同時に生存するオブジェクトの数) でクラッシュするのかを特定する。
- 原因がテスト側の後始末 (WebRTC オブジェクトの解放順・解放タイミング) にある場合はテストを修正する。SDK 側の解放経路にある場合は SDK を修正するが、公開 API は変えない。
- 反復回数や並行度を落としてクラッシュ確率を下げる対処はしない。0135 の検証内容 (実 WebRTC オブジェクトの交差を反復し、交差後に `sendMessage` が旧 DataChannel へ送信しないことを確認する) を弱めない。
- モックやスタブは利用しない。実 `MediaChannel` / 実 `PeerChannel` / 実 `RTCPeerConnection` / 実 `RTCDataChannel` を使う現状の方針を維持する。
- 原因が SDK / WebRTC 側にあり SDK から回避できないと判明した場合は、その事実と根拠を本 issue に記録し、`e2e` job の失敗条件を変えるかどうかは別途判断する (勝手に失敗条件を緩めない)。

## 完了条件

- クラッシュの再現条件と原因 (テスト側 / SDK 側 / WebRTC 側) が、実行して得た根拠つきで本 issue に記録されていること。
- 原因に応じた修正が入っていること。テスト側ならテストの修正、SDK 側なら SDK の修正 (公開 API は変えない)。
- 修正後に `e2e` job が同じクラッシュで失敗しないこと。実 CI での確認は、失敗した run は原因を記録したうえで再実行し、成功した回だけを数える。
- テストの検証内容を弱めていないこと。
- 変更後に `SoraTests` が Simulator で失敗 0 であること。

## 解決方法

{YYYY-MM-DD} に対応する。(未対応)
