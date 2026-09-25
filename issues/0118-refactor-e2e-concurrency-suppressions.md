# E2E テストの concurrency 診断抑止を除去する

- Created: 2026-08-27
- Completed:
- Branch: feature/refactor-e2e-concurrency-suppressions
- Polished: 2026-09-25

## 目的

E2E テストが `@testable @preconcurrency import Sora` と根拠のない `@unchecked Sendable` に依存する状態を解消し、診断を抑止せずに callback と test state の executor 境界をコードで保証する。

## 現状

`SoraTests/E2ETestBase.swift` と 10 の E2E test ファイルは、合計 11 箇所で `@testable @preconcurrency import Sora` を使用している。`SoraTests/DummyVideoCapturer.swift` は `@preconcurrency import Accelerate` を使用し、`DummyVideoCapturer` を class 全体で `@unchecked Sendable` にしている (lock と executor assertion は無い)。

`E2ETestBase` は `@MainActor` だが、SDK callback は WebSocket の直列 OperationQueue、`DispatchQueue.global()`、main RunLoop の Timer、libwebrtc の DataChannel / PeerConnection スレッドから到達する。SDK の handler 型は `@Sendable` ではない (`0110` が legacy handler の型を変えないと定めている) ため、handler 経由の state 更新は型検査では検出されない。型検査が検出するのは main actor isolation の診断と、`DispatchQueue.main` 以外の queue や `Timer` の block のような非 MainActor な `@Sendable` closure を跨ぐ capture である。

2026-09-25 に Xcode 26.6 / Swift 6.3.3 で `SoraTests` の全ファイルを `-swift-version 6` で型検査した実測は次のとおり。

- `@preconcurrency` の有無にかかわらず 44 warning / 0 error で、診断は完全に一致する。現時点の `@preconcurrency import Sora` は実際の診断を 1 件も抑止していない。除去の目的は、今後 Sora の公開 API に非 Sendable な型が加わったときに診断が無言で弱まる経路を消すことにある。
- concurrency に関係する診断は 24 件である。main actor isolation の診断 (`nonisolated` 文脈からの参照と更新) が `E2ETestBase.swift` の `setUp` / `tearDown` に 13 件、`SendonlyE2ETests.swift` の `setUp` に 4 件、non-Sendable な `MediaChannel` の capture が `SendonlyE2ETests.swift` に 7 件である。
- 残る 20 件は concurrency 以外である (非推奨 API 10、未使用の capture 4、weak 変数 3、未使用の戻り値 2、未使用の値 1)。本 issue では扱わない (「スコープ外」を参照)。

`@preconcurrency import Accelerate` を外すと `DummyVideoCapturer.swift` の `kvImage_ARGBToYpCbCrMatrix_ITU_R_601_4` の参照が concurrency error になる (実測)。これは C API annotation の不足を局所的に補う別の境界であり、本 issue では撤去せず理由をコメントに残す。

## 前提となる issue

- `0157` (完了 2026-09-25): `RPCErrorDetail.data` を deep-Sendable な表現に変更し、`SoraError.rpcServerError(detail:)` の concurrency 警告を解消した。本 issue の型検査はこの完了後の状態を前提にする。
- `0121` (open): `DummyAudioDevice` の共有状態競合の修正。`pcmGenerator` を `@Sendable` にするため、capture 側の `SineWaveGenerator` / `StereoSineWaveGenerator` も Sendable にする必要がある (`SendonlyE2ETests.swift` / `StereoAudioOutputE2ETests.swift` / `DummyStereoAudioLoopbackTests.swift` が `pcmGenerator: generator.generate` の形で capture している)。`0121` の設計方針と変更対象は `SineWaveGenerator` と `SendonlyE2ETests.swift` しか挙げておらず、`StereoSineWaveGenerator` / `StereoAudioOutputE2ETests.swift` / `DummyStereoAudioLoopbackTests.swift` が抜けている。生成器側の変更は本 issue では行えないため、`0121` の記述を更新して対象に含める (本 issue の変更対象にも `issues/0121-bug-fix-dummy-audio-device-state-races.md` を入れるが、`0121` は本 issue より先に実装されるため、実装前に `0121` 側の記述を確定させる)。`0121` が class の Sendable 化ではなく value 型化を採る場合、`pcmGenerator: generator.generate` は mutating メソッド参照になり `let` から呼べないため、`StereoAudioOutputE2ETests.swift` / `DummyStereoAudioLoopbackTests.swift` の修正も `0121` の対象に含める。`0121` 完了後の状態で concurrency 診断 0 件を達成するため、`0121` → 本 issue の順で実施する。
- `0119` (open): concurrency runtime stress CI の追加。本 issue が `setUp` / `tearDown` を async 化して `E2ETestBase` の契約を変えるため、`0119` が追加する stress test は本 issue 完了後の契約に追随する。`0119` は本 issue の完了を待たないと明記しているので、実施順序の調整は不要である。

## 設計方針

- 11 箇所の `@testable @preconcurrency import Sora` を通常の `@testable import Sora` へ変更する。
- `E2ETestBase` の `setUp` / `tearDown` を `override func setUp() async throws` / `override func tearDown() async throws` にし、`super` を `try await` で呼ぶ。`@MainActor` を付けた `XCTestCase` では同期版の override が nonisolated とみなされ MainActor の property を触れない。`@MainActor override func setUp()` は actor isolation が一致せず error になる (いずれも実測)。`SendonlyE2ETests` の `override func setUp()` も同じ理由で async 化する。
- callback から mutable state を更新する箇所は、`SendonlyE2ETests` / `SendrecvE2ETests` / `SimulcastE2ETests` / `MessagingE2ETests` / `RpcE2ETests` / `VideoHardMuteRollbackE2ETests` と同じく `DispatchQueue.main.async` で main queue に束ねる。`RecvonlyE2ETests` / `ConnectionTaskCancelE2ETests` / `PeerChannelConnectCompletionE2ETests` は hop を置かず connect callback 直下で代入しているが、`fulfill` と `wait` の hand-off で同期されており型検査でも検出されないため、本 issue では変更しない (「スコープ外」を参照)。SDK の handler は `@Sendable` ではないため、hop の有無は型検査では検出できない。
- `DispatchQueue.main` 以外の queue と、MainActor に推論されない `@Sendable` closure (`DispatchQueue.global()` の block、`Timer` の block、`Task.detached` など) を跨いで非 Sendable な型 (`MediaChannel` / `MediaStream` / `DummyVideoCapturer`) を capture しない。`DispatchQueue.main` の block は宣言上 `@Sendable` だが MainActor と推論されるため、非 Sendable な型を capture しても診断は出ない (実測)。この推論は `DispatchQueue.main` と直接書いた場合のもので、`let queue = DispatchQueue.main` のように変数へ退避して `queue.async` と書くと診断が戻るため、queue を変数に代入しない。判定は型検査の concurrency 診断 0 件で行い、`DispatchQueue.main` の capture を書き換える必要はない。
  - 実測で診断が出るのは `SendonlyE2ETests` の `testSendonlyDummyVideo` と `testSendonlyDummyAudio` である。原因は `Timer(timeInterval:repeats:block:)` の block が `@Sendable` で、その block が `channel` (非 Sendable) を capture していることである (`DispatchQueue.main.async` の capture list 自体は診断を出さない)。
  - 処方: main RunLoop 上での待機を `Timer` から `DispatchQueue.main.asyncAfter` に置き換える。`Timer` の block は MainActor に推論されない `@Sendable` closure であるのに対し、`DispatchQueue.main` の block は MainActor と推論されるため、`channel` の capture も MainActor 上での state 参照も診断にならない (実測で 0 件)。`channel.native?.connectionState` や `channel.senderStream` を参照する assert は `asyncAfter` の block と `getStats` の handler の中に置いたままで診断は出ない (`Timer` を残した場合だけ concurrency 診断が出る。実測で 4 件)。やむを得ず `@Sendable` closure を跨ぐ場合は、非 Sendable な `Statistics` を Sendable な値に詰め替えてから 1 hop する (`StereoAudioOutputE2ETests` の `audioCounts` と同じ方式)。
  - `testSendonlyDummyVideo` と `testSendonlyDummyAudio` は、connect callback では `XCTFail` と `expectation.fulfill()` だけを行い、`wait` の後に MainActor 上で `sora?.mediaChannels.first` から channel と `senderStream` を取得し、`DummyVideoCapturer` の生成と `start()` を行う。`Sora.connect` の handler は非 `@Sendable` のため型検査は通るが、実際には libwebrtc の delegate スレッドから呼ばれる。`DummyVideoCapturer` を `@MainActor` にした後も callback 直下で `start()` を呼ぶと、型検査では検出できない MainActor 実行時違反になるため、生成と開始を MainActor へ移す。
  - 他の 6 ファイル (Sendonly / Sendrecv / Simulcast / Messaging / Rpc / VideoHardMuteRollback) の `DispatchQueue.main.async` は `DispatchQueue.main` の block なので、非 Sendable な値を (暗黙に) capture しても concurrency 診断は出ない (実測)。import の変更以外は不要である。
- 本 issue の変更で新しい `@unchecked Sendable` を追加しない。実測では上の手段で concurrency 診断 0 件に到達し、テスト用の box は不要である。production API の concurrency defect を回避するために unchecked box を追加することもしない。SDK 側の修正が必要なら別の production issue として扱う。
- expectation の fulfill と test state の更新順序を同じ actor 上で決定する。
- `DummyVideoCapturer` は `@MainActor final class` に隔離し、`@unchecked Sendable` を削除する。`Timer` の block は MainActor に推論されない `@Sendable` closure なので、main RunLoop 上での実行を `MainActor.assumeIsolated` で表明してから `onTimer()` を呼ぶ。`DummyVideoCapturerTests` は `@MainActor` を付けて追随する。capturer は MainActor の test 本体で生成・所有し、`isRunning` / `frameCount` の assert も test 本体で行う (callback 直下で生成・`start()` すると、型検査は通っても MainActor 実行時違反になる)。`deinit` の `timer?.invalidate()` は nonisolated のまま (解放スレッドで実行される) で、この点は現状と同じである。
- `@preconcurrency import Accelerate` は上記の理由で残し、局所利用の理由を日本語コメントで書く。
- `VideoHardMuteRollbackE2ETests` の `ConnectResultBox` / `VideoSwitchRecorder` / `ChannelBox` は利用契約をコメントで明記した root 付きの `@unchecked Sendable` であり、本 issue では変更しない (対象外である理由を「スコープ外」に書く)。
- `.github/workflows/build.yml` に、`SoraTests` に `@preconcurrency import Sora` が無いことを検査する step を追加する。`0107` が consumer package に置いた `git grep -n -E '@testable|@preconcurrency' -- ':(glob)TestConsumers/Swift6Consumer/**/*.swift'` と同じ方式で、対象を `:(glob)SoraTests/**/*.swift`、pattern を `@preconcurrency[[:space:]]+(@testable[[:space:]]+)?import[[:space:]]+Sora` にする (`@preconcurrency @testable import Sora` のように属性の順序を変えた再追加も検出し、`@preconcurrency import Accelerate` は検出しない)。`SoraTests` を build するのは `e2e-test.yml` だが、この検査はソースの文字列検査で build を必要としないため、lint と同じ `build.yml` に置く。`git grep` は一致なしで exit 1 を返すため、step は「exit 1 を成功、0 とその他の終了コードを失敗」として判定する (`0107` の consumer-test.yml と同じ扱い)。warnings-as-errors は抑止された診断を検出できないため、`@preconcurrency` の再追加の防止はこの検査で行う。

## スコープ外

- `SoraTests` target の warnings-as-errors gate の導入と、それによって error になる concurrency 以外の警告 (非推奨 API / weak 変数 / 未使用の戻り値 / 未使用の capture / 未使用の値) の解消。`Package.swift` の manifest 変更を伴う build 構成の変更であり、`.treatAllWarnings(as: .error)` は PackageDescription 6.2 以降でしか使えないため tools version の更新 (`0108`) を前提とする。`.github/workflows/e2e-test.yml` の `build-for-testing` に `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` を追加する方式は、この build setting が scheme 内の全 target に効いて `Sora` target の 53 warning で先に落ちるため使えない (再現: `Sora/` を `-swift-version 6` で型検査すると 53 warning、`build-for-testing` に `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` を渡すと 22 error)。本 issue では扱わず、`0171` が扱う。
- `Sora` target の concurrency 警告 (`0113` が扱う retroactive conformance、`0155` が扱う `Sora.connect` の closure capture) と、`Sora` target の warnings-as-errors 化。
- E2E テストの `@unchecked Sendable` のうち、`VideoHardMuteRollbackE2ETests` の既存 3 box (利用契約をコメントで明記済み) の書き換え。
- `SoraTests` のその他の `@unchecked Sendable` (`CameraStateOwnerTests.swift` の `CapturerCollector`、`LoggerTests.swift` の `StringCollector` / `FlagBox`、`DummyAudioDeviceTests.swift` の `StereoToneProbe`、`DummyStereoAudioLoopbackTests.swift` の `AudioTestResult`) の書き換え。いずれも lock と利用契約のコメントを持つもので、本 issue では監査のみ行い変更しない。
- `RecvonlyE2ETests` / `ConnectionTaskCancelE2ETests` / `PeerChannelConnectCompletionE2ETests` の connect callback 直下の state 更新 (`connectedChannel` / `mediaChannel` / `connectCallbackCount` への代入) を main queue へ束ねる書き換え。`fulfill` と `wait` の hand-off で同期されており、型検査でも検出されないため、本 issue では変更しない。
- `SoraTests/DummyAudioDeviceTests.swift` の波形生成クラス (`SineWaveGenerator` / `StereoSineWaveGenerator`) の Sendable 化、およびそれに伴う `StereoAudioOutputE2ETests.swift` / `DummyStereoAudioLoopbackTests.swift` の `pcmGenerator` の capture の修正 (`0121` が扱う。生成器を Sendable にすれば capture の診断は発生しない)。

## 変更対象

- `SoraTests/E2ETestBase.swift`: import、`setUp` / `tearDown` の async 化
- `SoraTests/SendonlyE2ETests.swift`: import、`setUp` の async 化 (`api*` property 自体は変更しない。同期 `setUp` からの代入が async 化で解消する)、connect callback を `XCTFail` と `fulfill` だけにし、`wait` 後に MainActor で capturer を生成・`start()` する組み替え、`Timer` の `DispatchQueue.main.asyncAfter` への置き換え、`isRunning` / `frameCount` の assert の MainActor の test 本体への移動
- `SoraTests/SendrecvE2ETests.swift` / `SimulcastE2ETests.swift` / `MessagingE2ETests.swift` / `RpcE2ETests.swift` / `RecvonlyE2ETests.swift` / `StereoAudioOutputE2ETests.swift` / `ConnectionTaskCancelE2ETests.swift` / `PeerChannelConnectCompletionE2ETests.swift` / `VideoHardMuteRollbackE2ETests.swift`: import (実測では import 以外の concurrency 診断は出ない)
- `SoraTests/DummyVideoCapturer.swift`: `@MainActor` 化、`@unchecked Sendable` の削除、Timer callback の MainActor 表明、`@preconcurrency import Accelerate` の理由コメント
- `SoraTests/DummyVideoCapturerTests.swift`: `@MainActor` 化
- `.github/workflows/build.yml`: `SoraTests` の `@preconcurrency import Sora` を検出する step の追加
- `issues/0121-bug-fix-dummy-audio-device-state-races.md`: `StereoSineWaveGenerator` と `StereoAudioOutputE2ETests.swift` / `DummyStereoAudioLoopbackTests.swift` を変更対象に加える更新 (`0121` は本 issue より先に実装されるため、着手前に確定させる)
- `CHANGES.md`: `## develop` の `### misc` に `[UPDATE]` で「E2E テストの concurrency 診断抑止を除去する」を追記し、公開 API と利用者の挙動の変更がないことを補足行に書く (担当者行 `- @ユーザー名` を含める)

## テスト方針

モックやスタブは使用しない。

- `SoraTests` の全ファイルを Swift 6 (`-swift-version 6`) で型検査し、concurrency に関係する診断 (main actor isolation と Sendable の capture) が 0 件であることを確認する。判定は「20 warning / 0 error で、内訳が非推奨 API 10、未使用の capture 4、weak 変数 3、未使用の戻り値 2、未使用の値 1 と一致すること」で行う (2026-09-25 の実測値)。2026-09-25 にこの設計方針 (async な `setUp` / `tearDown`、`SendonlyE2ETests` の `Timer` の置き換え、`DummyVideoCapturer` の `@MainActor` 化と `MainActor.assumeIsolated`) を適用した型検査で、concurrency 診断 0 件・error 0 件になることを確認済みである。`0121` を先に完了させるため、型検査は `0121` 完了後の状態で再実行する。`Sora` module は E2E workflow の `build-for-testing` が作る `build/Build/Products/Debug-iphonesimulator` の成果物 (`-enable-testing` 付き) を使い、`XCTest` とあわせて `-I` / `-F` で読み込む。

  ```
  xcrun swiftc -typecheck -swift-version 6 \
    -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -target arm64-apple-ios14.0-simulator \
    -I build/Build/Products/Debug-iphonesimulator \
    -I "$(xcode-select -p)/Platforms/iPhoneSimulator.platform/Developer/usr/lib" \
    -F build/Build/Products/Debug-iphonesimulator \
    -F "$(xcode-select -p)/Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks" \
    -module-cache-path build/module-cache \
    $(find SoraTests -name '*.swift')
  ```
- 型検査に使う `Sora` module は、先に E2E workflow と同じ `build-for-testing` で Debug 構成の成果物を作り直す (古い成果物を検査しないため)。2026-09-25 の「`@preconcurrency` の有無で診断が一致する」という実測は、`-D DEBUG` と `-enable-testing` 付きで build した module を使った結果である。
- `git grep -n -E '@preconcurrency[[:space:]]+(@testable[[:space:]]+)?import[[:space:]]+Sora' -- ':(glob)SoraTests/**/*.swift'` が一致しないことを確認する (`0107` と同じく、git の既定の pathspec では `**/` が 0 階層に一致しないため `:(glob)` を付ける)。
- 実 Sora 接続を使う既存 E2E test を実行する。
- `DummyVideoCapturer` の start / stop / Timer callback が MainActor 上で実行されることを確認する。
- callback の連続到着中に test cancellation と tearDown を実行し、MainActor 外の state access がないことを確認する。
- テストには、callback から MainActor へ移動する理由と snapshot の境界を日本語コメントで記載する。

## 完了条件

- `SoraTests` に `@preconcurrency import Sora` が残っていないこと。
- `SoraTests` に `@preconcurrency import Sora` が無いことを検査する step が `.github/workflows/build.yml` にあること。
- 本 issue の変更で新しい `@unchecked Sendable` が追加されていないこと。
- `DummyVideoCapturer` から `@unchecked Sendable` が除去されていること。
- E2E test が `DispatchQueue.main` 以外の queue や `Timer` の block を跨いで非 Sendable な型を capture していないこと (型検査で concurrency 診断 0 件)。SDK の handler は `@Sendable` ではないため、handler 経由の state 更新の隔離は型検査では検出できず、レビューと実 Sora のテストで確認する。
- 既存 E2E test がすべて成功すること。
- `@preconcurrency import Accelerate` を残す理由が日本語コメントで説明されていること。
- `issues/0121-bug-fix-dummy-audio-device-state-races.md` の変更対象に `StereoSineWaveGenerator` と `StereoAudioOutputE2ETests.swift` / `DummyStereoAudioLoopbackTests.swift` が含まれていること。
- `CHANGES.md` の `## develop` の `### misc` に `[UPDATE]` で E2E テストの concurrency 診断抑止の除去が追記され、公開 API と利用者の挙動の変更がないことが補足されていること。

## 解決方法
