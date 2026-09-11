# reconnect E2E テストの API 失敗時の後始末を修正し、API 呼び出しの一時接続断に強くする

- Created: 2026-09-11
- Completed: {YYYY-MM-DD}
- Branch: feature/fix-reconnect-e2e-api-failure
- Polished: {YYYY-MM-DD}

## 目的

CI (`.github/workflows/ci.yml` の e2e ジョブ) で `SendonlyE2ETests.testSendonlyReconnect` が失敗した原因を修正する。 Sora API の一時的な接続断でテストが失敗したときに、後始末の不備による二次的な失敗 (unwaited expectations) を報告させず、API の失敗だけを報告させる。 あわせて API 呼び出しが keep-alive 接続の再利用に依存しないようにし、同じ一時接続断を起こりにくくする。

## 現状

CI (コミット `4c1f5724`) の `testSendonlyReconnect` で、以下の 2 件のエラーが報告された。

1. Sora API (DisconnectConnection) の POST が `NSURLErrorNetworkConnectionLost (-1005)` で失敗した。 この API 呼び出しは SDK を経由せず、テストが `URLSession.shared` で直接 POST している (`SoraTests/SendonlyE2ETests.swift` の `testSendonlyReconnect` と `testSendonlyDataChannelClose`) 。 直前の `testSendonlyDataChannelClose` では同じ API 呼び出しが成功しており、約 5 秒後の POST だけが失敗している。 失敗は即時で、peer address は Tailscale の CGNAT 帯である。 確立済み接続が失われたことによる失敗と見られ、`URLSession.shared` がプールした keep-alive 接続をサーバー側が閉じた後の再利用レースが最も整合的である。 POST はべき等扱いされず自動再試行されない。 過去の CI でも同 API 経路が -1001 タイムアウト (コミット `fef1ca87`) やサーバー全体の -1011 (コミット `d038d314`) で失敗しており、共有インフラの一時障害という分類と整合する。

2. API 失敗後の後始末で `disconnectExpectation` と `connect2Expectation` を `fulfill()` しただけで `wait` していないため、XCTest が `Failed due to unwaited expectations` を追加報告した。 XCTest の `failIfExpectationsNotWaitedFor` は `hasBeenWaitedOn` のみを検査し、`fulfill()` では `hasBeenWaitedOn` が立たない。 `testSendonlyReconnect` のエラーパスは `fulfill()` のみで `wait` しておらず、API 失敗時に必ず unwaited expectations が追加報告される。 このパターンは 0079 でのテスト追加時から存在し、エラーパスが実行されるまで潜在化していた。 コミット `fef1ca87` の CI でも同一の 2 expectation で再発している。 同じファイルの `testSendonlySwitched` と `testSendonlyDataChannelClose` は `XCTWaiter.wait(for:timeout: 0)` で expectation を消費しており、このパターンと揃っていない。

また、API 失敗時の別の問題として、API リクエストのタイムアウト (`request.timeoutInterval = 10`) と XCTest の wait タイムアウト (`wait(for:timeout:)` の 10 秒) が同じため、wait が先にタイムアウトすると API コールバックがテスト終了後に発火する。 コールバック内の `XCTFail` は次に実行中のテストへ誤帰属される。 コミット `fef1ca87` の CI では `testSendonlyDataChannelClose` の wait タイムアウト後に `testSendonlyDummyAudio` が開始され、前テストの API コールバックの `XCTFail` が `testSendonlyDummyAudio` の失敗として記録された。 `testSendonlyDummyAudio` は API を呼ばないため、エラーの出所が食い違っている。

## 設計方針

- `testSendonlyReconnect` の全エラーパスで、未 wait の expectation を `XCTWaiter.wait(for:timeout: 0)` で消費する。 `testSendonlySwitched` / `testSendonlyDataChannelClose` と同じパターンに揃える。
- API 呼び出しごとに使い捨ての `URLSession` を生成し、完了後に `invalidateAndCancel` する。 `URLSession.shared` がプールした keep-alive 接続を再利用しないようにする。
  - DisconnectConnection は再送すると二重切断になり得るため、リトライではなく接続の使い捨てで対処する。
  - 対象は `testSendonlyReconnect` と `testSendonlyDataChannelClose` の API 呼び出しの両方とする。
- API 呼び出しの XCTest wait タイムアウトを `request.timeoutInterval` より長くする (例: リクエスト 10 秒に対して wait 15 秒) 。 API コールバックが必ず wait の内側で発火するようにし、テスト終了後の `XCTFail` が次のテストへ誤帰属されないようにする。 対象は `testSendonlyReconnect` と `testSendonlyDataChannelClose` の両方とする。
- `CHANGES.md` の `## develop` に FIX として記載する。

## テスト方針

- `TEST_API_URL` を一時的に到達不能な値にして API 失敗パスを実際に踏み、unwaited expectations が報告されず API エラーのみが報告されることと、API 失敗が次のテストへ誤帰属されないことを確認する。 モックやスタブは使用しない。
- 通常の E2E を複数回実行し、`testSendonlyReconnect` が成功することを確認する。

## 完了条件

- `testSendonlyReconnect` の全エラーパスで unwaited expectations が報告されないこと。
- `TEST_API_URL` を到達不能にした確認で、API エラーのみが報告されること。
- API タイムアウト時に `XCTFail` が次のテストへ誤帰属されないこと。
- 通常の E2E で `testSendonlyReconnect` が成功すること。
- `SendonlyE2ETests.swift` の API 呼び出しが keep-alive 接続の再利用に依存しないこと。
- `CHANGES.md` に FIX が記載されていること。

## 変更対象ファイル

- `SoraTests/SendonlyE2ETests.swift`
- `CHANGES.md`

## 関連 issue

- `0079`: `testSendonlyReconnect` を追加した。 エラーパスで `fulfill()` のみを行い `wait` しないパターンもここで入った。
- `0081`: `testSendonlyDataChannelClose` を追加した。 こちらは `XCTWaiter.wait(for:timeout: 0)` で expectation を消費している。

## 解決方法
