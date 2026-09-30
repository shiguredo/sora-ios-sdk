# `SoraTests` target を warnings-as-errors にする

- Created: 2026-09-25
- Completed: 2026-09-30
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

- `SoraTests/ConnectionStateOwnerTests.swift`: `testBeginConnectionStartAcquiresAndReleasesInitialLock` と `testBeginAndEndAsyncOperationAdjustsCount` の `endAsyncOperation(shouldCancelDisconnectTimerBasedDisconnect:)` は、`_ =` を付けない裸の呼び出しで戻り値を暗黙に捨てていた。保存された切断要求が無いため `nil` を返す契約を、地点ごとにメッセージを変えた `XCTAssertNil` に残す。
- `SoraTests/StreamFrameOwnerTests.swift` の `testSettingRendererAfterPreviousRendererIsReleased` / `testRendererExchangeAfterPreviousRendererIsReleasedDropsOldAdapterEvents` と `SoraTests/ConnectionTimerLifecycleTests.swift` の `testStopReleasesTimer` の `weak var` は再代入しないため `weak let` にする (`weak let` は Swift 6.3 で有効で、`#WeakMutability` が消えることを実測済み)。解放の観測方法 (weak 参照を保持 → 強参照を `nil` → `XCTAssertNil`) は変えない。
- `SoraTests/SendonlyE2ETests.swift` の `testSendonlyReconnect` / `testSendonlySwitched` / `testSendonlyDataChannelClose` と `SoraTests/RpcE2ETests.swift` の `testRPCServerErrorReturnsDetail` の connect の完了 closure は、body で `self` を使わない (コンパイラの `capture 'self' was never used` が根拠) ため capture list から `[self]` を外す。`[self]` を外すと closure がテスト instance を強参照しなくなるが、`wait(for:)` の間は XCTest がテスト instance を保持するため観測は変わらない。closure の中身と実行 executor も変えない。
- `SoraTests/RpcE2ETests.swift` の `testRPCRaceWithDisconnectTerminatesAll` の `guard let sendonlyChannel` は束縛した値を利用しないため `guard sendonlyChannel != nil` にし、sendonly の接続が成立しなかった場合は `XCTFail` で失敗を残してから `cleanupChannels()` する。`testRequestSimulcastRid` の同名の束縛は `waitForOutboundR0AndR2` へ渡して使うため変更しない。
- 11 件の解消では assert の追加と capture list の削除だけを行い、既存テストが観測する値と実行 executor を変えない。

### 変更しない範囲

- 公開 API、target 構成、iOS deployment target、依存関係、`swiftLanguageModes`、`Sora` target の `swiftSettings` を変更しない。
- 非推奨 API を移行するためのテストの書き換えは行わない。
- `.github/workflows/build.yml` / `.github/workflows/consumer-test.yml` / `Makefile` を変更しない。
- `SoraTests/RpcE2ETests.swift:114` の connect 完了 closure の `[self]` は残す。body が `self.sora` を参照するためコンパイラが未使用と判定しなかった (`SimulcastE2ETests.swift:66` / `SendrecvE2ETests.swift:45` / `MessagingE2ETests.swift:186` の同型も残っている)。

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
- 既存テストがすべて成功すること。`xcodebuild test -scheme Sora-Package` が失敗 0 件であることを基準にする (2026-09-29 の `0184` の実測は 441 件実行 / skip 31 / 失敗 0 件)。検証環境の `xcodebuild test` は PTY 制約で起動できないことがあるため、起動できない場合は `build-for-testing` と `xcrun simctl spawn <iOS 26.5 の iPhone 17 Pro simulator> .../Agents/xctest <SoraTests.xctest の絶対 path>` (`SIMCTL_CHILD_DYLD_FRAMEWORK_PATH` を設定する) で代替する (`0184` の `## 解決方法` と同じ手順)。
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

### `Package.swift` の変更内容

`SoraTests` target の `swiftSettings` に `.treatAllWarnings(as: .error)` を先、`.treatWarning("DeprecatedDeclaration", as: .warning)` を後に追加した (`Sora` target と `swiftLanguageModes` は変更していない)。順序に依存する理由は `## 設計方針` の「gate の実装」にあるとおりで、逆順にすると非推奨 API の警告が error になることを実測でも確認した。

`.swiftLanguageMode(.v6)` と `.defaultIsolation` は追加していない。package initializer の `swiftLanguageModes: [.v6]` が `SoraTests` にも適用され、compile 行は既に `-swift-version 6` である。`.github/workflows/e2e-test.yml` は変更せず、既存の `build-for-testing` の経路をそのまま gate にした。

### gate で error になる 11 件の解消

- `SoraTests/ConnectionStateOwnerTests.swift`: `testBeginConnectionStartAcquiresAndReleasesInitialLock` の `endAsyncOperation { _ in false }` 1 件と `testBeginAndEndAsyncOperationAdjustsCount` の同 2 件は、`_ =` を付けない裸の呼び出しで戻り値を暗黙に捨てていた。保存された切断要求が無いため `nil` が返る契約を、地点ごとにメッセージを変えた `XCTAssertNil` に置き換えた
- `SoraTests/StreamFrameOwnerTests.swift`: `testSettingRendererAfterPreviousRendererIsReleased` と `testRendererExchangeAfterPreviousRendererIsReleasedDropsOldAdapterEvents` の `weak var weakFirstRenderer` を `weak let` にした
- `SoraTests/ConnectionTimerLifecycleTests.swift`: `testStopReleasesTimer` の `weak var weakTimer` を `weak let` にした
- `weak var` から `weak let` へ変えた 3 件はいずれも再代入が無く、解放の観測方法 (weak 参照を保持 → 強参照を `nil` → `XCTAssertNil`) は変えていない
- `SoraTests/SendonlyE2ETests.swift`: `testSendonlyReconnect` / `testSendonlySwitched` / `testSendonlyDataChannelClose` の connect 完了 closure から未使用の `[self]` を外した
- `SoraTests/RpcE2ETests.swift`: `testRPCServerErrorReturnsDetail` の connect 完了 closure から未使用の `[self]` を外し、`testRPCRaceWithDisconnectTerminatesAll` の `guard let sendonlyChannel` を `guard sendonlyChannel != nil` にした。束縛した値を後続で使わないため、sendonly の接続が成立しなかった場合は `XCTFail` で失敗を残してから `cleanupChannels()` する (`testRequestSimulcastRid` の同名の束縛は `waitForOutboundR0AndR2` に渡して使うため変更していない)
- closure の中身と実行 executor、assert が観測する値は変えていない。モックとスタブは使っていない
- `[self]` を外した箇所と `weak let` にした箇所には説明コメントを付けていない。同じ説明は `## 設計方針` の「gate で error になる 11 件の解消」にあり、capture list を持たないことと `weak let` であること自体から読み取れるためである

### 検証結果 (2026-09-30、Xcode 26.6 / Swift 6.3.3 / iphoneos26.5 / `e2e-test.yml` と同じ invocation、fresh な `-derivedDataPath build/0171`)

- `build-for-testing`: **TEST BUILD SUCCEEDED** / error 0 件
- `-module-name SoraTests ` を含む行は 4 行で、compile に関わる 3 行 (SwiftDriver / Swift-Compilation-Requirements / Swift-Compilation) すべてに `-warnings-as-errors -Wwarning DeprecatedDeclaration` がこの順で現れた (残り 1 行は `appintentsmetadataprocessor` で compile 行ではない)。`grep -F -- '-module-name SoraTests ' build/0171-build-for-testing.log | grep -Fq -- '-warnings-as-errors -Wwarning DeprecatedDeclaration'` が成功する
- `-module-name Sora ` の compile 行に `-warnings-as-errors` は現れない (0 件)
- `(file):(line):(col)` で重複を除いた警告は `Sora` 17 件 + `SoraTests` 17 件の 34 件。`SoraTests` の内訳は `StopwatchTests` 7 / `ConfigurationTests` 6 / `PeerChannelConnectEncodingTests` 2 / `ConnectionConfigurationSnapshotTests` 2 で、すべて `is deprecated` の warning である。解消対象の 11 件 (未使用の戻り値 / weak 変数 / 未使用の capture / 未使用の値) は現れない
- 退行検出 1: `ConnectionTimerLifecycleTests` の `testStopReleasesTimer` の `weak let` を `weak var` に一時的に戻して fresh な derived data で `build-for-testing` すると **TEST BUILD FAILED** (exit 65) になり、`ConnectionTimerLifecycleTests.swift:97:14: error: weak variable 'weakTimer' was never mutated; consider changing to 'let' constant` が報告された。確認後に元に戻した
- 退行検出 2: `swiftSettings` の 2 行を逆順にすると compile 行は `-Wwarning DeprecatedDeclaration -warnings-as-errors` になり、非推奨が error になって **TEST BUILD FAILED** した (`'spotlightEnabled' is deprecated` と `'Stopwatch' is deprecated` の error)。`0107` の `ConsumerLegacy` と同じ順序依存を確認した。確認後に元に戻した
- 追加確認: `swiftSettings` を外して 11 件の 1 つ (`weak var weakTimer`) を戻すと、同じ診断が warning のまま **TEST BUILD SUCCEEDED** し、compile 行に `-warnings-as-errors` は現れなかった。確認後に元に戻した
- 全体テスト: `xcodebuild test -scheme Sora-Package -derivedDataPath build -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' SWIFT_VERSION=6 ...` は 1 回目に検証環境の PTY 制約 (`Pseudo Terminal Setup Error ... Operation not permitted`) で起動できなかった。`build-for-testing` の生成物を `xcrun simctl spawn <booted UDID> .../Agents/xctest <abs path>/SoraTests.xctest` (`SIMCTL_CHILD_DYLD_FRAMEWORK_PATH=build/Build/Products/Debug-iphonesimulator`) で代替して **441 件実行 / skip 31 / 失敗 0 件** (`All tests passed`) を確認し、その後に再実行した `xcodebuild test` も **441 件実行 / skip 31 / 失敗 0 件** で **TEST SUCCEEDED** になった (2026-09-29 の `0184` の実測と同じ。skip の内訳は `SORA_SIGNALING_URL` 未設定 22 件、`TEST_API_URL` 未設定 2 件、カメラ 6 件、AudioSession 1 件)
- `make build`: **BUILD SUCCEEDED**、`Sora` の警告 17 件 / error 0 件で、`Sora` の compile 行に `-warnings-as-errors -Wwarning DeprecatedDeclaration` が現れる (`0108` の gate は維持されている)
- `rm -rf build/consumer` の後に `make consumer-build SCHEME=ConsumerCore`: **BUILD SUCCEEDED**。log に `-module-name SoraTests ` は 0 件で、`Sora` の compile 行は `-suppress-warnings` のままで `-warnings-as-errors` を含まない (consumer は `SoraTests` を build しないため manifest の gate と衝突しない)
- `make fmt-lint`: 成功 (exit 0)。`swiftlint lint --strict --cache-path build/swiftlint-cache`: 0 violations / 65 files
- `make api-check-fresh`: **BUILD SUCCEEDED** で「The committed API baseline matches the current Sora module.」— 公開 API baseline に差分は無く、再生成は不要
- `git status --short` は 9 entry (`CHANGES.md` / `Package.swift` / `SoraTests` の 5 file / `issues/0180-refactor-single-owner-media-channel-state.md` の変更と、`issues/0171-update-soratests-warnings-as-errors.md` の `issues/closed/` への rename) のみ。`.github/workflows/` と `Makefile` と `Sora/` は無変更
- `polish-code` での修正 (説明コメントの削除、`XCTAssertNil` のメッセージの地点別化、sendonly の接続が成立しなかった場合の `XCTFail` の追加) の後も再検証し、`build-for-testing` は error 0 件 / 警告 34 件、全体テストは代替手順で 441 件実行 / skip 31 / 失敗 0 件、`make build` / `make consumer-build SCHEME=ConsumerCore` / `make fmt-lint` / `swiftlint lint --strict` / `make api-check-fresh` はすべて成功した

### `0108` の `## スコープ外` の扱い

`0108` の `## スコープ外` は「`.github/workflows/e2e-test.yml` の `build-for-testing` への gate 追加も `0171` に含める」と書いているが、`0108` 自身の設計方針の「`SoraTests` の gate は `0171` が manifest の `swiftSettings` で行う」を本 issue の設計として確定した。`e2e-test.yml` は変更しておらず、`build-for-testing` の compile 行に flags が現れることを実測で確認した。`0108` は closed のため修正していない。

### 残った懸念

- 検証環境の sandbox が `~/Library/Caches/org.swift.swiftpm` への書き込みを拒否するため、`HOME` と `CFFIXED_USER_HOME` を `build/0171-home2` に向けて `xcodebuild` を実行した。manifest の解決結果と compile 行の flags は通常の `HOME` と変わらない
- 実サーバーを使う E2E (`SORA_SIGNALING_URL` / `TEST_SECRET_KEY` / `TEST_API_URL`) は検証環境で未設定のため skip されたままである。gate 追加後に実サーバーで E2E が通ることは CI (`e2e-test.yml`) の確認になる
- 非推奨 API の warning 34 件 (`Sora` 17 + `SoraTests` 17) は `0138` と `0115` の対象として warning のまま残した
