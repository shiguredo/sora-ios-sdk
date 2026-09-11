# reconnect E2E テストの API 失敗時の後始末を修正し、API 呼び出しの一時接続断に強くする

- Created: 2026-09-11
- Completed: 2026-09-11
- Branch: feature/fix-reconnect-e2e-api-failure
- Polished: {YYYY-MM-DD}

## 目的

CI (`.github/workflows/ci.yml` の e2e ジョブ) で `SendonlyE2ETests.testSendonlyReconnect` が失敗した原因を修正する。 Sora API の一時的な接続断でテストが失敗したときに、後始末の不備による二次的な失敗 (unwaited expectations) を報告させず、API の失敗だけを報告させる。 あわせて API 呼び出しが keep-alive 接続の再利用に依存しないようにし、同じ一時接続断を起こりにくくする。 後始末の共通ヘルパー (`E2ETestBase` の `disconnectAndVerify` / `disconnectAll`) が早期 return する経路でも unwaited expectations を残さないようにする。

## 現状

CI (コミット `4c1f5724`) の `testSendonlyReconnect` で、以下の 2 件のエラーが報告された。

1. Sora API (DisconnectConnection) の POST が `NSURLErrorNetworkConnectionLost (-1005)` で失敗した。 この API 呼び出しは SDK を経由せず、テストが `URLSession.shared` で直接 POST している (`SoraTests/SendonlyE2ETests.swift` の `testSendonlyReconnect` と `testSendonlyDataChannelClose`) 。 直前の `testSendonlyDataChannelClose` では同じ API 呼び出しが成功しており、約 5 秒後の POST だけが失敗している。 失敗は即時で、peer address は Tailscale の CGNAT 帯である。 確立済み接続が失われたことによる失敗と見られ、`URLSession.shared` がプールした keep-alive 接続をサーバー側が閉じた後の再利用レースが最も整合的である。 POST はべき等扱いされず自動再試行されない。 過去の CI でも同 API 経路が -1001 タイムアウト (コミット `fef1ca87`) やサーバー全体の -1011 (コミット `d038d314`) で失敗しており、共有インフラの一時障害という分類と整合する。

2. API 失敗後の後始末で `disconnectExpectation` と `connect2Expectation` を `fulfill()` しただけで `wait` していないため、XCTest が `Failed due to unwaited expectations` を追加報告した。 XCTest の `failIfExpectationsNotWaitedFor` は `hasBeenWaitedOn` のみを検査し、`fulfill()` では `hasBeenWaitedOn` が立たない。 `testSendonlyReconnect` のエラーパスは `fulfill()` のみで `wait` しておらず、API 失敗時に必ず unwaited expectations が追加報告される。 このパターンは 0079 でのテスト追加時から存在し、エラーパスが実行されるまで潜在化していた。 コミット `fef1ca87` の CI でも同一の 2 expectation で再発している。 同じファイルの `testSendonlySwitched` と `testSendonlyDataChannelClose` は `XCTWaiter.wait(for:timeout: 0)` で expectation を消費しており、このパターンと揃っていない。

また、API 失敗時の別の問題として、API リクエストのタイムアウト (`request.timeoutInterval = 10`) と XCTest の wait タイムアウト (`wait(for:timeout:)` の 10 秒) が同じため、wait が先にタイムアウトすると API コールバックがテスト終了後に発火する。 コールバック内の `XCTFail` は次に実行中のテストへ誤帰属される。 コミット `fef1ca87` の CI では `testSendonlyDataChannelClose` の wait タイムアウト後に `testSendonlyDummyAudio` が開始され、前テストの API コールバックの `XCTFail` が `testSendonlyDummyAudio` の失敗として記録された。 `testSendonlyDummyAudio` は API を呼ばないため、エラーの出所が食い違っている。

また、後始末の共通ヘルパーである `E2ETestBase.disconnectAndVerify` と `E2ETestBase.disconnectAll` は、expectation を生成して onDisconnect ハンドラを設定した直後の `guard channel.state != .disconnected else { return / continue }` で早期脱出する。 `fulfill()` では `hasBeenWaitedOn` が立たないため、この経路では expectation が未 wait のまま残り、テスト終了時に `Failed due to unwaited expectation '切断が完了すること'` が報告される。 ハンドラ設定前に onDisconnect が発火した場合は fulfill すらされない。 また、`disconnectAndVerify` は onDisconnect ハンドラ内で `XCTAssertEqual` / `XCTFail` を記録しており、wait がタイムアウトした後に切断が完了すると、その assertion が次に実行中のテストへ誤帰属され得る。 このヘルパーは 7 クラス / 18 テストが使用しており、`testSendonlyReconnect` の後始末も呼び出している。

## 設計方針

- `testSendonlyReconnect` の全エラーパスで、未 wait の expectation を `XCTWaiter.wait(for:timeout: 0)` で消費する。 `testSendonlySwitched` / `testSendonlyDataChannelClose` と同じパターンに揃える。
- `E2ETestBase.disconnectAndVerify` / `E2ETestBase.disconnectAll` の早期 return / continue の前に、生成済みの expectation を `XCTWaiter.wait(for:timeout: 0)` で消費する。 正常経路では元の wait に到達するため二重 wait にはならない。 また、`disconnectAndVerify` の onDisconnect ハンドラ内では assertion を記録せず、イベントを main queue に束ねて保持し、wait の後にテストメソッド側で検証する。
- API 呼び出しごとに使い捨ての `URLSession` を生成し、完了後に `invalidateAndCancel` する。 `URLSession.shared` がプールした keep-alive 接続を再利用しないようにする。
  - DisconnectConnection は再送すると二重切断になり得るため、リトライではなく接続の使い捨てで対処する。
  - 対象は `testSendonlyReconnect` と `testSendonlyDataChannelClose` の API 呼び出しの両方とする。
- API 呼び出しの XCTest wait タイムアウトを `request.timeoutInterval` より長くし、API コールバックの結果を保持して wait 後に検証する。 コールバック内では `XCTFail` を呼ばず、テスト終了後に発火しても次のテストへ誤帰属されないようにする。 対象は `testSendonlyReconnect` と `testSendonlyDataChannelClose` の両方とする。
- `buildConfiguration` が `SORA_SIGNALING_URL` の設定ミスで `InvalidURLError` を throw する経路は、通常運用では発生しない設定ミスのため対象外とする。 expectation 生成を `buildConfiguration` より後に移す案は見送る。
- `CHANGES.md` の `## develop` に FIX として記載する。

## テスト方針

- `TEST_API_URL` を一時的に到達不能な値にして API 失敗パスを実際に踏み、unwaited expectations が報告されず API エラーのみが報告されることと、API 失敗が次のテストへ誤帰属されないことを確認する。 モックやスタブは使用しない。
- 通常の E2E を複数回実行し、`testSendonlyReconnect` が成功することを確認する。

## 完了条件

- `testSendonlyReconnect` の初回接続失敗・API 失敗・切断検知失敗の各エラーパス (共通ヘルパー `E2ETestBase.disconnectAndVerify` / `disconnectAll` が生成する expectation を含む) で unwaited expectations が報告されないこと。
- `TEST_API_URL` を到達不能にした確認で、API エラーのみが報告されること。
- API タイムアウト時に `XCTFail` が次のテストへ誤帰属されないこと。
- 通常の E2E で `testSendonlyReconnect` が成功すること。
- `SendonlyE2ETests.swift` の API 呼び出しが keep-alive 接続の再利用に依存しないこと。
- 共通ヘルパーを利用する既存の E2E テストの後始末が回帰しないこと。
- 共通ヘルパーの切断イベント検証が wait 後に行われ、テスト終了後に assertion が記録されないこと。
- `CHANGES.md` に FIX が記載されていること。

## 変更対象ファイル

- `SoraTests/SendonlyE2ETests.swift`
- `SoraTests/E2ETestBase.swift`
- `CHANGES.md`

## 関連 issue

- `0079`: `testSendonlyReconnect` を追加した。 エラーパスで `fulfill()` のみを行い `wait` しないパターンもここで入った。
- `0081`: `testSendonlyDataChannelClose` を追加した。 こちらは `XCTWaiter.wait(for:timeout: 0)` で expectation を消費している。

## 解決方法

- `SoraTests/SendonlyE2ETests.swift` の `testSendonlyReconnect` で、エラーパスの expectation を `fulfill()` から `XCTWaiter.wait(for:timeout: 0)` に変更し、未 wait の expectation が残らないようにした。
- Sora API (DisconnectConnection) の呼び出しを使い捨ての `URLSessionConfiguration.ephemeral` に変更し、完了後に `invalidateAndCancel` するようにした。 `timeoutIntervalForResource` でリクエストの総時間を制限し、wait のタイムアウトを 15 秒にしてコールバックが通常は wait の内側で発火するようにした。
- API コールバック内では `XCTFail` を呼ばず、結果をクラスプロパティに保持して wait 後にテストメソッド側で検証するようにした。 コールバックがテスト終了後に発火しても次のテストへ失敗が誤帰属されない。
- `SoraTests/E2ETestBase.swift` の `disconnectAndVerify` / `disconnectAll` で、早期 return / continue の前に expectation を `XCTWaiter.wait(for:timeout: 0)` で消費するようにした。 `disconnectAndVerify` の onDisconnect ハンドラ内の assertion を削除し、イベントを main queue に束ねて保持して wait 後に検証するようにした。
- `CHANGES.md` の `## develop` に FIX を追記した。
- 検証: `make fmt-lint` / `make lint` / `xcodebuild build-for-testing` / `test-without-building` (197 テスト中 0 failures、E2E 21 件スキップ) を確認した。 E2E はコミット `95c8fab8` の CI で通過した。
