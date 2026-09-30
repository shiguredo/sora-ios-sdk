# `SoraTests` target を warnings-as-errors にする

- Created: 2026-09-25
- Completed: {YYYY-MM-DD}
- Priority: Low
- Branch: feature/update-soratests-warnings-as-errors
- Polished: 2026-09-30

## 目的

`SoraTests` target の warnings-as-errors gate を `Package.swift` の `SoraTests` target の `swiftSettings` で有効にし、テスト側の非推奨以外の警告を恒久的に検出できるようにする。

`Sora` target の gate は `0108` が repo の build 経路 (`Makefile` の `build` と `.github/workflows/build.yml` の `xcodebuild`) に `OTHER_SWIFT_FLAGS='-warnings-as-errors -Wwarning DeprecatedDeclaration'` で入れている。Xcode は package 依存の target の compile に `-suppress-warnings` を渡すため、manifest の `Sora` target の `swiftSettings` に `.treatAllWarnings(as: .error)` を置くと consumer の build が `conflicting options` で失敗するためである。`SoraTests` は consumer から build されないためこの制約を受けず、manifest で gate できる。`0108` は `SoraTests` target の gate を本 issue へ委譲し、`0118` は `SoraTests` の concurrency 診断の解消に専念して gate の導入を本 issue の担当として残したため、gate は本 issue が引き取る。

## 現状

- `Package.swift` は `swift-tools-version:6.3` で、package initializer に `swiftLanguageModes: [.v6]` を宣言している (`0108` 完了 2026-09-29)。`SoraTests` target に `swiftSettings` は無い。`Sora` target の warnings-as-errors gate は manifest には無く、repo の build 経路にだけある。
- `.github/workflows/e2e-test.yml` の `build-for-testing` は scheme `Sora-Package` (`Sora` と `SoraTests` の両方を build する) で `SWIFT_VERSION=6` のみを指定しており、warnings-as-errors は指定していない。
- `build-for-testing` に `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` を追加する方式は使えない。この build setting は scheme 内の全 target に効くため、後方互換のために非推奨 API を参照し続けている `Sora` target (実測で非推奨 API の警告 17 件) が先に落ちる。`0108` の実測では `OTHER_SWIFT_FLAGS` の `-Wwarning DeprecatedDeclaration` は `-warnings-as-errors` より前に並ぶため、この build setting と併用しても非推奨を降格できない。test target だけを gate するには manifest の target 個別の `swiftSettings` を使う (`0107` の consumer package と同じ方式)。
- 2026-09-30 の実測 (Xcode 26.6 / Swift 6.3.3 / `iphoneos26.5` / `.github/workflows/e2e-test.yml` の `build-for-testing` と同じ invocation) は **TEST BUILD SUCCEEDED** で、警告は 45 件 (`Sora` 17 件 + `SoraTests` 28 件) / error 0 件である。件数は同じ警告が `SwiftEmitModule` と `SwiftCompile` の両方の log に出るため、`(file):(line):(col)` で重複を除いて数える。`SoraTests` の 28 件の内訳は非推奨 API 17 件 (`StopwatchTests` 7 / `ConfigurationTests` 6 / `PeerChannelConnectEncodingTests` 2 / `ConnectionConfigurationSnapshotTests` 2) と、本 issue の gate で error になる次の 11 件である。
  - 未使用の戻り値 3 (`ConnectionStateOwnerTests` の `endAsyncOperation(shouldCancelDisconnectTimerBasedDisconnect:)`)
  - weak 変数 3 (`StreamFrameOwnerTests` 2 / `ConnectionTimerLifecycleTests` 1)
  - 未使用の capture 4 (`SendonlyE2ETests` 3 / `RpcE2ETests` 1)
  - 未使用の値 1 (`RpcE2ETests` の `guard let sendonlyChannel`)
- `SoraTests` の concurrency 診断 (`#SendableClosureCaptures` / `add '@preconcurrency'` / actor isolation / `sending`) は 0 件である (`0118` 完了 2026-09-25 の実測どおり)。
- `SoraTests` の compile 行は現在 `-swift-version 6` だけで、`-suppress-warnings` と `-warnings-as-errors` のどちらも含まない (2026-09-30 の実測)。manifest の `swiftSettings` を足しても衝突する option は無い。
- `SwiftSetting.treatAllWarnings(as:)` と `treatWarning(_:as:)` は PackageDescription 6.2 以降の API で、`0108` の tools version 6.3 への更新により利用できる前提は満たされている。

## 前提となる issue

完了済み:

- `0121` (完了 2026-09-25): `DummyAudioDevice` の共有状態競合の修正。`pcmGenerator` の `@Sendable` 化に伴い、テストの波形生成器 (`SineWaveGenerator` / `StereoSineWaveGenerator`) の可変状態を lock で保護した。
- `0118` (完了 2026-09-25): E2E テストの concurrency 診断抑止の除去。`SoraTests` の concurrency 診断が 0 件になった。gate を先に有効にすると concurrency 診断で build が落ちるため、本 issue の前提である。
- `0108` (完了 2026-09-29): `swift-tools-version` を 6.3 に上げ、`swiftLanguageModes: [.v6]` を宣言した。`SoraTests` target の `swiftSettings` は追加しておらず、本 issue の担当である。`SwiftSetting.treatAllWarnings(as:)` を使う前提を満たす。

open (着手順を調整する相手):

- `0141` (open): `SignalingChannel` を WebSocket 接続管理に純化する。`SoraTests/ConnectionTimerLifecycleTests.swift` を変更対象にしている。本 issue が同 file で変更するのは `testStopReleasesTimer` の `weak let` 化 1 箇所だけで、`0141` は `SignalingChannel` の生成箇所を変える大規模な refactor で未着手である。本 issue を先に実施し、`0141` は本 issue の完了後に develop から分岐する。
- `0057` (open): `SoraTests/StreamFrameOwnerTests.swift` の拡張を計画している。本 issue が同 file で変更するのは `weak let` 化 2 箇所だけで、`0057` が追加するテストとは重ならない。`0057` は本 issue の後に実施する。
- `0119` (open): `e2e-test.yml` に Thread Sanitizer の job を追加し、`SoraTests` にテストを追加する。本 issue は `e2e-test.yml` を変更しないため競合しないが、`0119` が追加するテストは本 issue の gate を満たす必要があるため、本 issue を先に実施する。
- `0180` (open): `SoraTests` が warnings-as-errors になった後のテストを追加する。本 issue を先に実施する。
- `0138` (open): 非推奨 API の SDK 内部利用の解消。テストが後方互換検証のために意図的に参照する非推奨 API は `0138` の対象外であり、本 issue でも warning のまま残す。
- `0115` (pending): `Utilities.Stopwatch` の削除。削除されれば `StopwatchTests` の非推奨 7 件も消えるが、本 issue では扱わない。

## 設計方針

### gate の実装

- `Package.swift` の `SoraTests` target の `swiftSettings` に `.treatAllWarnings(as: .error)` を先、`.treatWarning("DeprecatedDeclaration", as: .warning)` を後に書く。SwiftPM は宣言順に `-warnings-as-errors` と `-Wwarning DeprecatedDeclaration` を連続させて並べる (`0107` の `ConsumerLegacy` で実測済み)。逆順にすると非推奨が error になり build できない。
- `.swiftLanguageMode(.v6)` と `.defaultIsolation` は追加しない。package initializer の `swiftLanguageModes: [.v6]` が `SoraTests` にも適用され、`SoraTests` の compile 行は既に `-swift-version 6` である (2026-09-30 の実測)。default isolation を変える必要も無い。
- `Sora` target の `swiftSettings` は追加しない。`0108` の設計どおり gate は repo の build 経路に置いたままにする。
- `.github/workflows/e2e-test.yml` は変更しない。根拠は次の 2 つである。
  - `SoraTests` は root package の test target であり、consumer package (`TestConsumers/Swift6Consumer`) の依存グラフに含まれない。2026-09-29 の consumer build の log に `-module-name SoraTests` の compile 行は 0 件で、consumer は `SoraTests` を build しない。したがって consumer が受け取る `-suppress-warnings` と衝突しない。
  - manifest の `swiftSettings` は `xcodebuild` が `SoraTests` を build するときの compile 行に `-warnings-as-errors -Wwarning DeprecatedDeclaration` として現れるため、既存の `build-for-testing` の経路がそのまま gate になる。workflow 側に flag を足す必要が無い。
- `0108` の `## スコープ外` は「`.github/workflows/e2e-test.yml` の `build-for-testing` への gate 追加も `0171` に含める」と書くが、`0108` 自身の設計方針は「`SoraTests` の gate は `0171` が manifest の `swiftSettings` で行う」と書いている。後者を本 issue の設計として確定し、`e2e-test.yml` は変更しない。`0108` は closed のため修正せず、本 issue の `## 解決方法` にこの確定内容を記録する。

### 非推奨 API を warning のまま残す

- `Sora` target の 17 件は `Sora/` 内の非推奨 API の参照 (SDK が後方互換のために残す API の内部参照と、iOS SDK 由来の deprecation) である。`SoraTests` の 17 件はテストが後方互換検証のために意図的に参照する非推奨 API (`Utilities.Stopwatch`、`Configuration.spotlightEnabled`、`ICEServerInfo` の非推奨イニシャライザ、`Configuration.insecure`) である。発生源は別だが同じ `DeprecatedDeclaration` であり、`0108` の gate と本 issue の gate がどちらも error にしない対象は合計 34 件になる。
- `SoraTests` 側の 17 件を warning のまま残すのは、`0138` がテストの非推奨参照を対象外としているためである。`-Wwarning DeprecatedDeclaration` は diagnostic group 単位で降格するため、非推奨だけが warning に残り、それ以外の警告は error になる。

### gate で error になる 11 件の解消

- `SoraTests/ConnectionStateOwnerTests.swift`: `testBeginConnectionStartAcquiresAndReleasesInitialLock` と `testBeginAndEndAsyncOperationAdjustsCount` の `endAsyncOperation(shouldCancelDisconnectTimerBasedDisconnect:)` は、保存された切断要求が無いため `nil` を返す。`_ =` で捨てず `XCTAssertNil(..., "非同期処理の終了だけでは切断要求を取り出さないこと")` のように、契約を示す日本語メッセージ付きの assert に残す。
- `SoraTests/StreamFrameOwnerTests.swift` の `testSettingRendererAfterPreviousRendererIsReleased` / `testRendererExchangeAfterPreviousRendererIsReleasedDropsOldAdapterEvents` と `SoraTests/ConnectionTimerLifecycleTests.swift` の `testStopReleasesTimer` の `weak var` は再代入しないため `weak let` にする (`weak let` は Swift 6.3 で有効で、`#WeakMutability` が消えることを実測済み)。解放の観測方法 (weak 参照を保持 → 強参照を `nil` → `XCTAssertNil`) は変えない。
- `SoraTests/SendonlyE2ETests.swift` の `testSendonlyReconnect` / `testSendonlySwitched` / `testSendonlyDataChannelClose` と `SoraTests/RpcE2ETests.swift` の `testRPCServerErrorReturnsDetail` の connect の完了 closure は、body で `self` を使わない (コンパイラの `capture 'self' was never used` が根拠) ため capture list から `[self]` を外す。`[self]` を外すと closure がテスト instance を強参照しなくなるが、`wait(for:)` の間は XCTest がテスト instance を保持するため観測は変わらない。closure の中身と実行 executor も変えない。
- `SoraTests/RpcE2ETests.swift` の `testRPCRaceWithDisconnectTerminatesAll` の `guard let sendonlyChannel` は束縛した値を利用しないため `guard sendonlyChannel != nil` にする。`testRequestSimulcastRid` の同名の束縛は `waitForOutboundR0AndR2` へ渡して使うため変更しない。
- 11 件の解消では assert の追加と capture list の削除だけを行い、既存テストが観測する値と実行 executor を変えない。

### 変更しない範囲

- 公開 API、target 構成、iOS deployment target、依存関係、`swiftLanguageModes`、`Sora` target の `swiftSettings` を変更しない。
- 非推奨 API を移行するためのテストの書き換えは行わない。
- `.github/workflows/build.yml` / `.github/workflows/consumer-test.yml` / `Makefile` を変更しない。

## スコープ外

- `Sora` target の warnings-as-errors gate (`0108` が repo の build 経路に置いた。本 issue の対象外)。
- `SoraTests` の concurrency 診断の解消 (`0118` で完了済み)。
- 非推奨 API を参照しているテストの書き換え (非推奨 API の移行)。`0138` はテストの非推奨参照を対象外としており、`Utilities.Stopwatch` の削除は `0115` (pending) が担当する。非推奨 API 自体の廃止は本 issue では扱わない。

## 変更対象

- `Package.swift`: `SoraTests` target の `swiftSettings` に `.treatAllWarnings(as: .error)` と `.treatWarning("DeprecatedDeclaration", as: .warning)` をこの順で追加する。`Sora` target と `swiftLanguageModes` は変更しない。
- `SoraTests/ConnectionStateOwnerTests.swift`: `endAsyncOperation(shouldCancelDisconnectTimerBasedDisconnect:)` の戻り値の未使用を `XCTAssertNil` で解消する。
- `SoraTests/StreamFrameOwnerTests.swift` / `SoraTests/ConnectionTimerLifecycleTests.swift`: `weak var` を `weak let` にする。
- `SoraTests/SendonlyE2ETests.swift` / `SoraTests/RpcE2ETests.swift`: 未使用の `[self]` capture を削除し、未使用の値の束縛を boolean test にする。
- `CHANGES.md`: `## develop` の `### misc` に `[UPDATE]` で「`SoraTests` target を warnings-as-errors にする」を追記し、公開 API と利用者の挙動の変更がないことを補足行に書く (担当者行 `- @<GitHub handle>` を含める。直近の変更は `- @t-miya`)。機能に直接影響しない build 構成の変更のため主リストではなく `### misc` に置き、`### misc` の中では種別の順に従って既存の `[UPDATE]` の後・最初の `[FIX]` の前に置く。

## テスト方針

モックやスタブは使用しない。検証は Xcode 26.6 / `iphoneos26.5` / iOS 26.5 simulator で行い、`.github/workflows/e2e-test.yml` の `build-for-testing` と同じ invocation を使う。incremental build では compile が省略されて flags が log に残らないため、log を取る前に専用の `-derivedDataPath` を消す。

```
rm -rf build/0171
mkdir -p build
set -o pipefail && xcodebuild build-for-testing \
  -scheme Sora-Package -sdk iphoneos26.5 \
  -derivedDataPath build/0171 \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= PROVISIONING_PROFILE= \
  SWIFT_VERSION=6 2>&1 | tee build/0171-build-for-testing.log
```

- `** TEST BUILD SUCCEEDED **` であること。
- `-module-name SoraTests ` の compile 行に `-warnings-as-errors -Wwarning DeprecatedDeclaration` がこの順で連続して現れること。`grep -F -- '-module-name SoraTests ' build/0171-build-for-testing.log | grep -Fq -- '-warnings-as-errors -Wwarning DeprecatedDeclaration'` で確認する。
- `-module-name Sora ` の compile 行に `-warnings-as-errors` が現れないこと (`Sora` の gate は repo の build 経路にだけ置く)。
- `SoraTests` の警告が非推奨 API の 17 件だけであること。件数は `(file):(line):(col)` で重複を除いて数える。次のように数えることを想定している。

  ```
  grep -oE '^/[^ ]*SoraTests/[^ ]*\.swift:[0-9]+:[0-9]+: warning:.*' build/0171-build-for-testing.log | sort -u | wc -l
  ```

  xcodebuild は diagnostic group 名を出力しないため、非推奨が warning のまま残ることは件数ではなく symbol 名 (`Stopwatch` / `spotlightEnabled` / `init(urls:userName:credential:tlsSecurityPolicy:)` / `insecure`) が log に現れることで判定する。
- 既存テストがすべて成功すること。`xcodebuild test -scheme Sora-Package` が失敗 0 件であることを基準にする (2026-09-29 の `0184` の実測は 441 件実行 / skip 31 / 失敗 0 件)。検証環境の `xcodebuild test` は PTY 制約で起動できないため、起動できない場合は `build-for-testing` と `xcrun simctl spawn <iOS 26.5 の iPhone 17 Pro simulator> .../Agents/xctest <SoraTests.xctest の絶対 path>` (`SIMCTL_CHILD_DYLD_FRAMEWORK_PATH` を設定する) で代替する (`0184` の `## 解決方法` と同じ手順)。
- `make fmt-lint` と `swiftlint lint --strict` が成功すること (`make lint` は検証環境の sandbox 制限で失敗することがあるため、`swiftlint lint --strict` の直接実行で代替する)。
- `make api-check-fresh` が成功し、公開 API baseline に差分が出ていないこと (公開 API を変更しないため再生成は不要)。
- 退行検出 1: 解消した 11 件のうち 1 つ (例: `ConnectionTimerLifecycleTests` の `testStopReleasesTimer` の `weak let` を `weak var` に戻す) を一時的に戻し、`build-for-testing` が `-warnings-as-errors` で失敗することを確認する。確認用の変更は commit しない。
- 退行検出 2: `swiftSettings` の 2 行を逆順にすると非推奨 17 件が error になって `build-for-testing` が失敗することを確認する (`0107` の `ConsumerLegacy` と同じ確認)。確認後に戻す。
- 退行検出 3: `rm -rf build/consumer` の後に `make consumer-build SCHEME=ConsumerCore` を実行し、consumer の build が成功して `Sora` target の compile 行が `-suppress-warnings` のままで `-warnings-as-errors` を含まず、consumer の log に `-module-name SoraTests ` が現れないことを確認する。

## 完了条件

- `Package.swift` の `SoraTests` target の `swiftSettings` が `.treatAllWarnings(as: .error)`、`.treatWarning("DeprecatedDeclaration", as: .warning)` の順で、`Sora` target の `swiftSettings` と `swiftLanguageModes` を変更していないこと。
- fresh な derived data での `xcodebuild build-for-testing` が成功し、`SoraTests` の compile 行に `-warnings-as-errors -Wwarning DeprecatedDeclaration` がこの順で現れ、`Sora` target の compile 行に `-warnings-as-errors` が現れないこと。
- `SoraTests` の警告が非推奨 API の 17 件だけで、11 件 (未使用の戻り値 / weak 変数 / 未使用の capture / 未使用の値) が解消されていること。
- 既存テストがすべて成功すること (`xcodebuild test -scheme Sora-Package` または同等の代替手順で失敗 0 件。基準は 441 件実行 / skip 31)。
- 公開 API、target 構成、iOS deployment target、依存関係、`swiftLanguageModes` が変わっておらず、`make api-check-fresh` が成功すること。
- `make fmt-lint` と `swiftlint lint --strict` が成功すること。
- 退行検出 1 (`SoraTests` の警告が error になること) と退行検出 2 (`swiftSettings` の順序を逆にすると非推奨が error になること) で、gate が効いていることと順序依存を確認していること。
- `.github/workflows/e2e-test.yml` / `.github/workflows/build.yml` / `.github/workflows/consumer-test.yml` / `Makefile` を変更していないこと。
- `CHANGES.md` の `## develop` の `### misc` に `[UPDATE]` が担当者行付きで追加され、公開 API と利用者の挙動の変更がないことが補足されていること。
- `## 解決方法` に、`e2e-test.yml` を変更せず manifest の `SoraTests` の `swiftSettings` で gate したことと、`0108` の `## スコープ外` の記述をこの設計で確定したことが記録されていること。

## 解決方法
