# E2E テストの concurrency 診断抑止を除去する

- Created: 2026-08-27
- Completed:
- Priority: Medium
- Branch: feature/refactor-e2e-concurrency-suppressions
- Polished: 2026-09-25

## 目的

E2E テストが `@testable @preconcurrency import Sora` と根拠のない `@unchecked Sendable` に依存する状態を解消し、診断を抑止せずに callback と test state の executor 境界をコードで保証する。

## 現状

`SoraTests/E2ETestBase.swift` と 10 の E2E test ファイルは、合計 11 箇所で `@testable @preconcurrency import Sora` を使用している。`SoraTests/DummyVideoCapturer.swift` は `@preconcurrency import Accelerate` を使用し、`DummyVideoCapturer` を class 全体で `@unchecked Sendable` にしている (lock と executor assertion は無い)。

`E2ETestBase` は `@MainActor` だが、SDK callback は WebSocket の直列 OperationQueue、`DispatchQueue.global()`、main RunLoop の Timer、libwebrtc の DataChannel / PeerConnection スレッドから到達する。SDK の handler 型は `@Sendable` ではない (`0110` が legacy handler の型を変えないと定めている) ため、handler 経由の state 更新は型検査では検出されない。型検査が検出するのは main actor isolation の診断と、`DispatchQueue.main` 以外の queue や `Timer` の block のような非 MainActor な `@Sendable` closure を跨ぐ capture である。

2026-09-25 に Xcode 26.6 / Swift 6.3.3 で確認した実測は次のとおり。

- swiftc の単発の型検査 (`-swift-version 6` で `SoraTests` の全ファイルをまとめて型検査) では、`@preconcurrency` の有無にかかわらず 44 warning / 0 error で診断が一致する。
- 一方、実ビルド (`xcodebuild build-for-testing`) では `@preconcurrency` を外すと `RpcE2ETests.swift` に 3 件の error が出る。`sending 'channel' risks causing data races` (`MediaChannel.rpc` は nonisolated の async で、MainActor 隔離の channel を渡すと region isolation の error になる)。`@preconcurrency` はこの 3 件の error を warning に落として抑止している。swiftc の型検査で出ないのは、実ビルドが explicit module build (`-explicit-swift-module-map-file` と `-disable-implicit-swift-modules`) で module を読み込むためで、**判定は実ビルドで行う必要がある**。
- concurrency に関係する診断は、swiftc の型検査で 24 件である。main actor isolation の診断 (`nonisolated` 文脈からの参照と更新) が `E2ETestBase.swift` の `setUp` / `tearDown` に 13 件、`SendonlyE2ETests.swift` の `setUp` に 4 件、non-Sendable な `MediaChannel` の capture が `SendonlyE2ETests.swift` に 7 件である。
- 残る 20 件は concurrency 以外である (非推奨 API 10、未使用の capture 4、weak 変数 3、未使用の戻り値 2、未使用の値 1)。本 issue では扱わない (「スコープ外」を参照)。

`@preconcurrency import Accelerate` を外すと `DummyVideoCapturer.swift` の `kvImage_ARGBToYpCbCrMatrix_ITU_R_601_4` の参照が concurrency error になる (実測)。これは C API annotation の不足を局所的に補う別の境界であり、本 issue では撤去せず理由をコメントに残す。

## 前提となる issue

- `0157` (完了 2026-09-25): `RPCErrorDetail.data` を deep-Sendable な表現に変更し、`SoraError.rpcServerError(detail:)` の concurrency 警告を解消した。本 issue の型検査はこの完了後の状態を前提にする。
- `0121` (open): `DummyAudioDevice` の共有状態競合の修正。`pcmGenerator` を `@Sendable` にするため、capture 側の `SineWaveGenerator` / `StereoSineWaveGenerator` も Sendable にする必要がある (`SendonlyE2ETests.swift` / `StereoAudioOutputE2ETests.swift` / `DummyStereoAudioLoopbackTests.swift` / `DummyAudioDeviceTests.swift` が `pcmGenerator:` にメソッド参照 (`generator.generate`) または closure を渡している)。`0121` の当初の設計方針と変更対象は `SineWaveGenerator` と `SendonlyE2ETests.swift` しか挙げておらず `StereoSineWaveGenerator` / `StereoAudioOutputE2ETests.swift` / `DummyStereoAudioLoopbackTests.swift` / `DummyAudioDeviceTests.swift` が抜けていたため、本 issue の変更対象として `0121` の記述を更新した。`pcmGenerator` が非 `@Sendable` のままでも本 issue の変更で concurrency 診断は 0 件になる (実測) ため、本 issue の実装は `0121` の完了を待たない。`0121` を実施する際に capture 側の 4 ファイルを追随させる。
- `0119` (open): concurrency runtime stress CI の追加。本 issue が `setUp` / `tearDown` を async 化して `E2ETestBase` の契約を変えるため、`0119` が追加する stress test は本 issue 完了後の契約に追随する。`0119` は本 issue の完了を待たないと明記しているので、実施順序の調整は不要である。

## 設計方針

- 11 箇所の `@testable @preconcurrency import Sora` を通常の `@testable import Sora` へ変更する。
- `E2ETestBase` の `setUp` / `tearDown` を `override func setUp() async throws` / `override func tearDown() async throws` にし、`super` を `try await` で呼ぶ。`@MainActor` を付けた `XCTestCase` では同期版の override が nonisolated とみなされ MainActor の property を触れない。`@MainActor override func setUp()` は actor isolation が一致せず error になる (いずれも実測)。`SendonlyE2ETests` の `override func setUp()` も同じ理由で async 化する。
- callback から mutable state を更新する箇所は、`SendonlyE2ETests` / `SendrecvE2ETests` / `SimulcastE2ETests` / `MessagingE2ETests` / `RpcE2ETests` / `VideoHardMuteRollbackE2ETests` と同じく `DispatchQueue.main.async` で main queue に束ねる。`RecvonlyE2ETests` / `ConnectionTaskCancelE2ETests` / `PeerChannelConnectCompletionE2ETests` / `StereoAudioOutputE2ETests` は hop を置かず connect callback 直下で代入しているが、`fulfill` と `wait` の hand-off で同期されており型検査でも検出されないため、本 issue では変更しない (「スコープ外」を参照)。SDK の handler は `@Sendable` ではないため、hop の有無は型検査では検出できない。
- `DispatchQueue.main` 以外の queue と、MainActor に推論されない `@Sendable` closure (`DispatchQueue.global()` の block、`Timer` の block、`Task.detached` など) を跨いで非 Sendable な型 (`MediaChannel` / `MediaStream` / `DummyVideoCapturer`) を capture しない。`DispatchQueue.main` の block は宣言上 `@Sendable` だが MainActor と推論されるため、非 Sendable な型を capture しても診断は出ない (実測)。この推論は `DispatchQueue.main` と直接書いた場合のもので、`let queue = DispatchQueue.main` のように変数へ退避して `queue.async` と書くと診断が戻るため、queue を変数に代入しない。判定は実ビルドの concurrency 診断 0 件で行い、`DispatchQueue.main` の capture を書き換える必要はない。
  - 実測で診断が出るのは `SendonlyE2ETests` の `testSendonlyDummyVideo` と `testSendonlyDummyAudio` である。原因は `Timer(timeInterval:repeats:block:)` の block が `@Sendable` で、その block が `channel` (非 Sendable) を capture していることである (`DispatchQueue.main.async` の capture list 自体は診断を出さない)。
  - 処方: main RunLoop 上での待機を `Timer` から `DispatchQueue.main.asyncAfter` に置き換える。`Timer` の block は MainActor に推論されない `@Sendable` closure であるのに対し、`DispatchQueue.main` の block は MainActor と推論されるため、`channel` の capture も MainActor 上での state 参照も診断にならない (実測で 0 件)。`channel.native?.connectionState` や `channel.senderStream` を参照する assert は `asyncAfter` の block と `getStats` の handler の中に置いたままで診断は出ない (`Timer` を残した場合だけ concurrency 診断が出る。実測で 4 件)。やむを得ず `@Sendable` closure を跨ぐ場合は、非 Sendable な `Statistics` を Sendable な値に詰め替えてから 1 hop する (`StereoAudioOutputE2ETests` の `audioCounts` と同じ方式)。
  - `MediaChannel.getStats` の handler は `@Sendable` ではないため、`DispatchQueue.main` の block の中から渡すと MainActor 隔離を継承する。handler は WebRTC のスレッドから呼ばれるので、その中の closure 呼び出し (`first(where:)` など) が実行時違反 (`dispatch_assert_queue` で SIGTRAP) になる (2026-09-25 の E2E で実測)。handler には `@Sendable` を明示して隔離を継承させず、`Statistics` は Sendable な snapshot に詰め替えてから main queue へ hop する。assert と検証 closure は main queue 上で実行し、検証 closure も `@Sendable` にする (非 Sendable な closure を handler の中へ持ち込むと `sending` の error になる)。`channel` を参照する assert は handler の外 (test 本体) に置く (`@Sendable` closure は非 Sendable な `channel` を capture できない)。
  - `testSendonlyDummyVideo` と `testSendonlyDummyAudio` は、connect callback では `DispatchQueue.main.async` に束ねて失敗の報告 (成功時は `mediaChannel` が渡る契約の検証) と `connectedChannel` への保持だけを行い、`wait` の後に `connectedChannel` から `senderStream` を取得する (`DummyVideoCapturer` の生成と `start()` は `testSendonlyDummyVideo` だけが行う)。接続に失敗した場合は `sora?.mediaChannels` に残っているチャンネルを切断してから戻る (接続に失敗しても、一覧から外れるのは切断完了の通知が届いたときである)。`Sora.connect` の handler は非 `@Sendable` のため型検査は通るが、実際には libwebrtc の delegate スレッドから呼ばれる。`DummyVideoCapturer` を `@MainActor` にした後も callback 直下で `start()` を呼ぶと、型検査では検出できない MainActor 実行時違反になるため、生成と開始を MainActor へ移す。
  - 他の 6 ファイル (Sendonly / Sendrecv / Simulcast / Messaging / Rpc / VideoHardMuteRollback) の `DispatchQueue.main.async` は `DispatchQueue.main` の block なので、非 Sendable な値を (暗黙に) capture しても concurrency 診断は出ない (実測)。import の変更以外は不要である。
- `RpcE2ETests` の `MediaChannel.rpc` 呼び出しは、`MediaChannel` をまとめた `@unchecked Sendable` の box (`RPCChannelBox`) 経由に組み替える。`MediaChannel` は Sendable ではなく `rpc` は nonisolated の async のため、MainActor 隔離のテストから直接呼ぶと region isolation の error になる (実ビルドで実測)。box の利用契約は「テスト内の利用に限定した unchecked box であり、実行文脈を揃えるものではない」とし、可変状態を持たず参照だけを保持することと、安全性が `MediaChannel` の内部同期に依存することを日本語コメントで明記する。実行文脈が一致することを契約にしてはならない (`VideoHardMuteRollbackE2ETests` の `ChannelBox` にある「テストと同じ実行文脈で操作する」という記述は実装と一致しないため、本 issue で是正する)。SDK の concurrency defect を隠すための box は追加しない。この box は非 Sendable な `MediaChannel` を actor 境界へ持ち込まないためのテスト内限定のものであり、SDK 側の修正が必要になった場合は別の production issue として扱う。
- expectation の fulfill と test state の更新順序を同じ actor 上で決定する。
- `DummyVideoCapturer` は `@MainActor final class` に隔離し、`@unchecked Sendable` を削除する。`Timer` の block は MainActor に推論されない `@Sendable` closure なので、main RunLoop 上での実行を `MainActor.assumeIsolated` で表明してから `onTimer()` を呼ぶ。`DummyVideoCapturerTests` は `@MainActor` を付けて追随し、実 `MediaChannel` / `MediaStream` を使って Timer の発火と `stop()` による停止を確認するテストを追加する。capturer は MainActor の test 本体で生成・所有し、`isRunning` / `frameCount` の assert も test 本体で行う (callback 直下で生成・`start()` すると、型検査は通っても MainActor 実行時違反になる)。`deinit` は nonisolated で実行されるため `@MainActor` の `Timer?` を参照できない (実ビルドで `cannot access property 'timer' with a non-Sendable type 'Timer?' from nonisolated deinit` になる) ので、`isolated deinit` にして MainActor 上で `timer?.invalidate()` を実行する。`timer` の生成と無効化が MainActor 上の `start` / `stop` と `deinit` だけで行われることを日本語コメントで明記し、診断を抑止する `nonisolated(unsafe)` は使わない (`isolated deinit` が Xcode 26.6 / Swift 6.3.3 の実ビルドで利用できることは実測)。
- `@preconcurrency import Accelerate` は上記の理由で残し、局所利用の理由を日本語コメントで書く。
- `VideoHardMuteRollbackE2ETests` の `ConnectResultBox` / `VideoSwitchRecorder` / `ChannelBox` は利用契約をコメントで明記した root 付きの `@unchecked Sendable` であり、本 issue では設計を変更しない (`ChannelBox` の実行文脈に関する記述だけを是正する。詳細は「スコープ外」)。
- `.github/workflows/build.yml` に、`SoraTests` が `@preconcurrency` で concurrency 診断を抑止していないことを検査する step を追加する。対象を `:(glob)SoraTests/**/*.swift` とし、検出は「一致した行から、コメント行と `@preconcurrency import Accelerate` を除いたものが残っていれば失敗」とする。行の形 (属性の順序・属性の単独行・行末コメント・セミコロン) に依存させないためである (`@preconcurrency` を `import Sora` の直前以外に使う新しい抑止が必要になった場合は、検出をすり抜けさせず許容条件を見直すことになる)。`@preconcurrency import Accelerate` は C API の注釈不足を補うために残すので許容する。検査対象が 0 件のまま成功しないよう、先に `git ls-files -- ':(glob)SoraTests/**/*.swift'` が 1 件以上あることを確認する。`SoraTests` を build するのは `e2e-test.yml` だが、この検査はソースの文字列検査で build を必要としないため、lint と同じ `build.yml` に置き、`set -o pipefail` を設定する。warnings-as-errors は抑止された診断を検出できないため、`@preconcurrency` の再追加の防止はこの検査で行う。

## スコープ外

- `SoraTests` target の warnings-as-errors gate の導入と、それによって error になる concurrency 以外の警告 (非推奨 API / weak 変数 / 未使用の戻り値 / 未使用の capture / 未使用の値) の解消。`Package.swift` の manifest 変更を伴う build 構成の変更であり、`.treatAllWarnings(as: .error)` は PackageDescription 6.2 以降でしか使えないため tools version の更新 (`0108`) を前提とする。`.github/workflows/e2e-test.yml` の `build-for-testing` に `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` を追加する方式は、この build setting が scheme 内の全 target に効いて `Sora` target の 53 warning で先に落ちるため使えない (再現: `Sora/` を `-swift-version 6` で型検査すると 53 warning、`build-for-testing` に `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` を渡すと 22 error)。本 issue では扱わず、`0171` が扱う。
- `Sora` target の concurrency 警告 (`0113` が扱う retroactive conformance、`0155` が扱う `Sora.connect` の closure capture) と、`Sora` target の warnings-as-errors 化。
- E2E テストの `@unchecked Sendable` のうち、`VideoHardMuteRollbackE2ETests` の既存 3 box (`ConnectResultBox` / `VideoSwitchRecorder` / `ChannelBox`) の設計の書き換え。3 box とも利用契約をコメントで明記済みで、本 issue では `ChannelBox` の実行文脈に関する記述の是正だけを行う (設計は変更しない)。
- `SoraTests` のその他の `@unchecked Sendable` (`CameraStateOwnerTests.swift` の `CapturerCollector`、`LoggerTests.swift` の `StringCollector` / `FlagBox`、`DummyAudioDeviceTests.swift` の `StereoToneProbe`、`DummyStereoAudioLoopbackTests.swift` の `AudioTestResult`) の書き換え。いずれも lock と利用契約のコメントを持つもので、本 issue では監査のみ行い変更しない。
- `RecvonlyE2ETests` / `ConnectionTaskCancelE2ETests` / `PeerChannelConnectCompletionE2ETests` / `StereoAudioOutputE2ETests` の connect callback 直下の state 更新 (`connectedChannel` / `mediaChannel` / `connectCallbackCount` への代入) を main queue へ束ねる書き換え。`fulfill` と `wait` の hand-off で同期されており、型検査でも検出されないため、本 issue では変更しない。
- `SoraTests/DummyAudioDeviceTests.swift` の波形生成クラス (`SineWaveGenerator` / `StereoSineWaveGenerator`) の Sendable 化、およびそれに伴う `SendonlyE2ETests.swift` / `StereoAudioOutputE2ETests.swift` / `DummyStereoAudioLoopbackTests.swift` / `DummyAudioDeviceTests.swift` の `pcmGenerator` の capture の修正 (`0121` が扱う。生成器を Sendable にすれば capture の診断は発生しない)。

## 変更対象

- `SoraTests/E2ETestBase.swift`: import、`setUp` / `tearDown` の async 化
- `SoraTests/SendonlyE2ETests.swift`: import、`setUp` の async 化 (`api*` property 自体は変更しない。同期 `setUp` からの代入が async 化で解消する)、connect callback の state 更新を main queue へ束ねる組み替えと接続待ちの private ヘルパーへの集約、`wait` 後に MainActor で capturer を生成・`start()` する組み替え、`Timer` の `DispatchQueue.main.asyncAfter` への置き換え、`isRunning` / `frameCount` の assert の MainActor の test 本体への移動
- `SoraTests/SendrecvE2ETests.swift` / `SimulcastE2ETests.swift` / `MessagingE2ETests.swift` / `RecvonlyE2ETests.swift` / `StereoAudioOutputE2ETests.swift` / `ConnectionTaskCancelE2ETests.swift` / `PeerChannelConnectCompletionE2ETests.swift`: import (実測では import 以外の concurrency 診断は出ない)
- `SoraTests/VideoHardMuteRollbackE2ETests.swift`: import、`ChannelBox` の利用契約コメントの是正 (実行文脈の一致を契約にしない。box の設計は変更しない)
- `SoraTests/RpcE2ETests.swift`: import、`MediaChannel.rpc` 呼び出しを `RPCChannelBox` 経由に組み替え (利用契約のコメントを含む)、未使用の `attempt` 引数と `rpcTask` 保持の削除
- `SoraTests/DummyVideoCapturer.swift`: `@MainActor` 化、`@unchecked Sendable` の削除、Timer callback の MainActor 表明、`timer` の `isolated deinit` 化と理由コメント、`if let timer` の除去、`@preconcurrency import Accelerate` の理由コメント
- `SoraTests/DummyVideoCapturerTests.swift`: `@MainActor` 化、既存の `testDeinitInvalidatesTimer` を「stop せずに解放しても解放が完了すること」の検証へ書き換え、実 `MediaChannel` / `MediaStream` を使った repeating な Timer の発火と `stop()` による停止の検証を追加
- `SoraTests/E2ETestBaseLifecycleTests.swift` (新規): async な `setUp` / `tearDown` が同期の test method でも呼ばれることの検証
- `SoraTests/StreamFrameOwnerTestHelpers.swift`: 共有ヘルパーの利用者に `DummyVideoCapturerTests` を追記 (コメントのみ)
- `.github/workflows/build.yml`: `SoraTests` の `@preconcurrency import Sora` を検出する step の追加 (検査対象が 0 件のときに成功しないことの確認を含む)
- `issues/0121-bug-fix-dummy-audio-device-state-races.md`: `StereoSineWaveGenerator` と `StereoAudioOutputE2ETests.swift` / `DummyStereoAudioLoopbackTests.swift` / `DummyAudioDeviceTests.swift` を変更対象に加える更新
- `CHANGES.md`: `## develop` の `### misc` に `[UPDATE]` で「E2E テストの concurrency 診断抑止を除去する」を追記し、公開 API と利用者の挙動の変更がないことを補足行に書く (担当者行 `- @ユーザー名` を含める)

## テスト方針

モックやスタブは使用しない。

- **判定は実ビルドで行う**。swiftc の単発の型検査は explicit module build と診断が一致しない (実測で `sending` の error を見落とす)。E2E workflow と同じ invocation で `SoraTests` を build する。

  ```
  xcodebuild build-for-testing \
    -scheme Sora-Package \
    -sdk iphoneos26.5 \
    -derivedDataPath build \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY= \
    PROVISIONING_PROFILE= \
    SWIFT_VERSION=6
  ```

  concurrency に関係する診断 (main actor isolation / Sendable の capture / `sending` / `nonisolated deinit`) が 0 件で、concurrency 以外の 20 warning (非推奨 API 10、weak 変数 3、未使用の戻り値 2、未使用の capture 4、未使用の値 1) だけが残ることを確認する。この 20 件は本 issue では解消せず、`0171` の完了で非推奨 API 10 件だけになる (`0171` は weak 変数 / 未使用の戻り値 / 未使用の capture / 未使用の値も解消する)。
- 補助として swiftc の型検査も使う。`Sora` module は先に `build-for-testing` で Debug 構成の成果物を作り直す (古い成果物を検査しないため)。

  ```
  xcrun swiftc -typecheck -swift-version 6 -D DEBUG \
    -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -target arm64-apple-ios14.0-simulator \
    -I build/Build/Products/Debug-iphonesimulator \
    -I "$(xcode-select -p)/Platforms/iPhoneSimulator.platform/Developer/usr/lib" \
    -F build/Build/Products/Debug-iphonesimulator \
    -F "$(xcode-select -p)/Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks" \
    -module-cache-path build/module-cache \
    $(find SoraTests -name '*.swift')
  ```

  concurrency 診断 0 件で、warning は実ビルドと同じ 20 件になる (2026-09-25 の実測。変更前は concurrency 24 件を含む 44 warning だった)。
- `.github/workflows/build.yml` の検査 step を、現在の作業ツリーでそのまま実行し、`@preconcurrency import Accelerate` だけを持つ状態で成功することを確認する。あわせて `git ls-files -- ':(glob)SoraTests/**/*.swift'` が 0 件でないことを確認する (`SoraTests` の改名や pathspec の誤りで検査が無言で無効にならないことの確認。検査対象が 0 件でも `git grep` は exit 1 になるため、CI の step は file 数の確認を先に行う)。
- `xcodebuild test-without-building` で `DummyVideoCapturerTests` を実行し、`@MainActor` 化後も start / stop / Timer callback が動くことを確認する (実 `MediaChannel` / `MediaStream` を使い、repeating な Timer が複数の frame を送信することと、`stop()` 後に frame が増えないことを検証する)。`deinit` の `timer?.invalidate()` は、Timer の block が `self` を weak で capture するため直接は観測できない。無効化の検証は `stop()` の経路で行い、`deinit` の経路は「stop せずに解放しても解放が完了すること」だけを確認する。
- async な `setUp` が同期の test method でも呼ばれることを確認する。環境変数の有無に依存せず常に実行される `E2ETestBaseLifecycleTests` で検証する (2026-09-25 に、`SORA_SIGNALING_URL` を到達不能な URL、`TEST_SECRET_KEY` を非空にして `RecvonlyE2ETests.testConnectRecvonly` を実行し、両方が設定済みのため `XCTSkip` にならず接続エラーで即座に失敗することでも確認済み)。async な `tearDown` 自体の呼び出しはテスト内から観測できないため、`super.tearDown()` の内容 (`sora` の解放) を確認する。
- 実 Sora 接続を使う既存 E2E test を実行する。
- callback の連続到着中に test cancellation と tearDown を実行し、本 issue が変更するテストの state access が MainActor 上で行われることを確認する (`RecvonlyE2ETests` / `ConnectionTaskCancelE2ETests` / `PeerChannelConnectCompletionE2ETests` の connect callback 直下の state 更新は「スコープ外」のとおり本 issue では変更しない)。
- テストには、callback から MainActor へ移動する理由と snapshot の境界を日本語コメントで記載する。

## 完了条件

- `SoraTests` に `@preconcurrency import Sora` が残っていないこと。
- `SoraTests` に `@preconcurrency import Sora` が無いことを検査する step が `.github/workflows/build.yml` にあり、検査対象が 0 件のときに成功しないこと。
- `DummyVideoCapturer` から `@unchecked Sendable` が除去されていること。
- 実ビルド (`xcodebuild build-for-testing`) で `SoraTests` の concurrency 診断 (main actor isolation / Sendable の capture / `sending` / `nonisolated deinit`) が 0 件であること。
- 新しく追加した `@unchecked Sendable` に、利用契約と理由が日本語コメントで書かれていること (実行文脈が一致することを契約として書いていないこと)。
- `DummyVideoCapturerTests` が成功し、repeating な Timer の発火と `stop()` による停止を検証するテストが含まれていること。
- async な `setUp` の呼び出しと async な `tearDown` の後始末がテストで検証されていること。
- 既存 E2E test がすべて成功すること。
- `@preconcurrency import Accelerate` を残す理由が日本語コメントで説明されていること。
- `issues/0121-bug-fix-dummy-audio-device-state-races.md` の変更対象に `StereoSineWaveGenerator` と `StereoAudioOutputE2ETests.swift` / `DummyStereoAudioLoopbackTests.swift` / `DummyAudioDeviceTests.swift` が含まれていること。
- `CHANGES.md` の `## develop` の `### misc` に `[UPDATE]` で E2E テストの concurrency 診断抑止の除去が追記され、公開 API と利用者の挙動の変更がないことが補足されていること。

## 解決方法
