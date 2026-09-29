# Swift 5 言語モードの consumer が Sora を import して build できることを検証する

- Created: 2026-09-29
- Completed: 2026-09-29
- Priority: Low
- Branch: feature/add-swift5-consumer-verification
- Polished: {YYYY-MM-DD}

## 目的

`swift-tools-version` 6.3 と `swiftLanguageModes: [.v6]` により、SwiftPM で取り込んだ consumer は SDK (`Sora` target) を Swift 6 言語モードで compile する。ただし consumer 自身の target は consumer 側の `swiftSettings` で compile されるため、アプリの言語モードは SDK の manifest では決まらない。

Swift 5 言語モードのままのアプリが `import Sora` して build できることを CI で固定する。SDK が Swift 6 言語モードで compile されることと、その SDK を Swift 5 言語モードのアプリが利用できることは別の契約であり、後者は現状検証されていない。

## 優先度根拠

検証の追加であり、SDK の公開 API と挙動を変えない。Swift 5 言語モードの consumer の互換性は現時点で壊れていないため、リリースを妨げない。時間があれば対応する Low とする。

## 現状

- root の `Package.swift` は `swift-tools-version:6.3` で、package initializer に `swiftLanguageModes: [.v6]` を宣言している (`0108`)。`Sora` target は Swift 6 言語モードで compile される。
- consumer package は `TestConsumers/Swift6Consumer` の 1 つで、`ConsumerCore` / `ConsumerUI` / `ConsumerLegacy` の 3 target を持つ。3 target はすべて `swiftSettings` に `.swiftLanguageMode(.v6)` を明示しており、Swift 5 言語モードで compile される target は無い。
- `ConsumerLegacy` は「非推奨 API を使っても build できる」シナリオであり、言語モードの検証ではない。
- 2026-09-29 の実測 (`Xcode 26.6` / `iphoneos26.5`): `make consumer-build` の log で `-module-name Sora ` の compile 行は `-swift-version 6` と `-suppress-warnings` が付く。`-warnings-as-errors` は含まない。consumer の 3 target の compile 行も `-swift-version 6` である。
- したがって、Swift 5 言語モードのアプリが SDK を import して build できることは CI で検証されていない。`0108` の実測でも「`-swift-version 5` で走る compile 行は 3 scheme で 0 件」と記録されている。

## 設計方針

- `TestConsumers/Swift6Consumer` に `ConsumerSwift5` target と、対応する library product を 1 つ追加する。`swiftSettings` に `.swiftLanguageMode(.v5)` を明示し、consumer 自身が Swift 5 言語モードで compile されることを build log で確認できるようにする。新規 package は作らない (root package への path 依存、負例の仕組み、公開 API baseline の運用を共有するため)。
- scenario は Swift 5 言語モードのアプリで典型的な使い方を公開 API で再現する。`Configuration` の組み立てと `Sora.shared.connect(configuration:handler:)`、`MediaChannel` の取得と統計取得、`MediaStream` への `VideoRenderer` の設定、`VideoView` の操作を含める。モックとスタブは使わない。
- 警告の扱い (`.defaultIsolation(nil)` と `.treatAllWarnings(as: .error)` を付けるか) は実測で決める。Swift 5 言語モードでは strict concurrency の診断が最小になるため通る可能性がある。通らない場合は、どの診断が原因で外したかを issue の「解決方法」に記録し、外すか `.treatWarning` で調整する。
- `.github/workflows/consumer-test.yml` の scheme 一覧と compiler settings の検査、deprecation symbol の検査、test-only import の検査に新 scheme を既存 3 scheme と同じ扱いで組み込む。新 scheme は `-swift-version 5` で compile されるため、`-swift-version` の検査は target ごとの compile 行で行う。
- 公開 API baseline は公開 API を変えないため再生成しない (差分が出た場合は別 issue とする)。
- `CHANGES.md` の `## develop` の `### misc` に `[ADD]` エントリを追加する。SDK の公開 API と挙動の変更が無いことを補足行に書く。

## 変更対象

- `TestConsumers/Swift6Consumer/Package.swift`: `ConsumerSwift5` の library product と target を追加する
- `TestConsumers/Swift6Consumer/Sources/ConsumerSwift5/`: 新規 target の scenario (Swift 5 言語モードのアプリで典型的な公開 API の使い方) を追加する
- `.github/workflows/consumer-test.yml`: scheme 一覧に `ConsumerSwift5` を追加し、build step と compiler settings の検査を新 scheme に対応させる
- `TestConsumers/Swift6Consumer/README.md`: 構成と担当の表に `ConsumerSwift5` を追加する
- `CHANGES.md`: `## develop` の `### misc` に `[ADD]` エントリを追加する

## テスト方針

モックやスタブは使用しない。検証は `Xcode 26.6` と `iphoneos26.5` (着手時点の `Makefile` の `API_XCODE` / `XCODE_SDK`) で行う。incremental build では compile が省略されて flags が log に出ないため、log を取る前に `rm -rf build/consumer` を実行する。

- `make consumer-build SCHEME=ConsumerSwift5` が **BUILD SUCCEEDED** になり、log の `-module-name ConsumerSwift5 ` の compile 行が `-swift-version 5`、`-module-name Sora ` の compile 行が `-swift-version 6` であること。
- 既存の 3 scheme (`ConsumerCore` / `ConsumerUI` / `ConsumerLegacy`) も **BUILD SUCCEEDED** であること。
- `make consumer-check-negative` が既存の 2 件の負例を期待どおり失敗させること。
- `.github/workflows/consumer-test.yml` の検査 (`Check Compiler Settings` / `Check Deprecation Warning` / `Check No Test-Only Import`) と同じ内容をローカルで再現して成功すること。
- `make build` / `make fmt-lint` / `swiftlint lint --strict --cache-path build/swiftlint-cache` が成功すること。
- 全体テスト (`xcodebuild test -scheme Sora-Package`) が失敗 0 件であること (基準は 441 件 / skip 31)。PTY 制約で起動できない場合は `build-for-testing` と `xcrun simctl spawn ... xctest` で代替する。
- 退行検出: `ConsumerSwift5` の `.swiftLanguageMode(.v5)` を `.v6` に変えると compile 行が `-swift-version 6` になり、本 issue の検証が成立しないことを確認する (確認後に戻す)。

## 完了条件

- `ConsumerSwift5` の product と target が追加され、`swiftSettings` に `.swiftLanguageMode(.v5)` が明示されていること。
- `make consumer-build SCHEME=ConsumerSwift5` の log で `-module-name ConsumerSwift5 ` の compile 行が `-swift-version 5`、`-module-name Sora ` の compile 行が `-swift-version 6` であること。
- `.github/workflows/consumer-test.yml` が `ConsumerSwift5` を build し、scheme の存在・compiler settings・test-only import の検査の対象に含めていること。
- 既存 3 scheme の build、`make consumer-check-negative`、`make build`、`make fmt-lint`、`swiftlint lint --strict`、全体テストが成功すること。
- 公開 API と `Sora` / `SoraTests` / root の `Package.swift` / `Makefile` / `.github/workflows/build.yml` を変更していないこと。
- `CHANGES.md` の `## develop` の `### misc` に `[ADD]` エントリが担当者行付きで追加されていること。

## 前提となる issue

- `0108` (完了 2026-09-29): `swift-tools-version` を 6.3 に上げ、`swiftLanguageModes: [.v6]` を宣言する。本 issue の検証は「SDK が Swift 6 言語モードで compile されること」と「Swift 5 言語モードの consumer がその SDK を import できること」を分けて確認するため、`0108` の後に実施する。
- `0107` (完了 2026-09-24): Swift 6 consumer package と公開 API baseline を追加する。本 issue は追加した package、`make consumer-build`、`make consumer-check-negative`、`.github/workflows/consumer-test.yml` をそのまま使う。
- `0171` (open): `SoraTests` target の warnings-as-errors gate。本 issue は test target の gate を変更しない。

## スコープ外

- SDK 側の変更 (`Sora/` と `SoraTests/`、root の `Package.swift`)。本 issue は consumer 側の検証だけを追加する
- `0108` の warnings-as-errors gate (`Makefile` の `build` と `.github/workflows/build.yml` の `OTHER_SWIFT_FLAGS`)
- `0171` の `SoraTests` target の gate
- Swift 5 言語モードで consumer に出る警告を SDK 側の gate にすること
- 公開 API baseline の再生成 (公開 API を変えないため差分は出ない見込み)。差分が出た場合は別 issue とする
- Swift 5 言語モードのアプリの実行時挙動の検証 (本 issue は compile できることだけを検証する)

## 解決方法

### 追加した target

- `TestConsumers/Swift6Consumer/Package.swift` に `ConsumerSwift5` の library product と target を追加した。`swiftSettings` は `.swiftLanguageMode(.v5)`、`.defaultIsolation(nil)`、`.treatAllWarnings(as: .error)` の順で、既存の `ConsumerCore` と同じ形にした
- `TestConsumers/Swift6Consumer/Sources/ConsumerSwift5/Swift5Compatibility.swift` を追加した。Swift 5 言語モードのアプリで典型的な形で公開 API を利用する。モックとスタブは使っておらず、この target は実行経路を持たず compile だけを検証する
  - `Configuration` の組み立てと `signalingConnectMetadata` への Codable な値の設定、`Sora.shared.connect(configuration:handler:)` (handler が self を capture する)、`ConnectionTask` の cancel、`MediaChannel.getStats(handler:)` と `sendMessage(label:data:)`、`MediaChannel` の公開プロパティの参照
  - `VideoRenderer` の nonisolated な実装と `MediaStream.videoRenderer` への設定、`MediaStream` の公開プロパティの参照
  - `@MainActor` の文脈での `VideoView` の生成と操作
  - main queue の完了 closure からの `MediaChannel` の参照
  - nonisolated な global shared mutable state (`var sharedSwift5Client = Swift5SoraClient()`)

### 警告の扱いの決定

2026-09-29 の実測 (Xcode 26.6 / Swift 6.3.3) で決めた。

- `.defaultIsolation(nil)` は Swift 5 言語モードでも `-default-isolation nonisolated` として渡り build できる。既定隔離の検査を既存 target と揃えるため付けた
- `.treatAllWarnings(as: .error)` は付けた。scenario に残した書き方は warning 0 件で通るため、この target の warnings-as-errors を弱めずに済む
- 明示的に `@Sendable` と書いた closure への非 Sendable な capture だけは、Swift 5 言語モードでも warning ("this is an error in the Swift 6 language mode") になり warnings-as-errors で error になった。`.treatWarning("SendableClosureCaptures", as: .warning)` で降格すると同じ診断群の gate がこの target で無効になるため、降格ではなくその書き方を scenario から外した。同じ capture は `NegativeChecks/core-sendable-capture.swift` が Swift 6 言語モードの負例として検査し続ける
- 代わりに nonisolated な global shared mutable state を scenario に含めた。Swift 6 言語モードでは `MutableGlobalVariable` の error、Swift 5 言語モードでは診断なしになる (同じ flags の型検査で実測)。この契約により、consumer の言語モードが実際に Swift 5 であることが source 側でも担保される
- main queue の完了 closure からの `MediaChannel` の capture は Swift 5 と Swift 6 のどちらでも診断されないことを実測した。この書き方は言語モードの差ではなく、main queue へ戻して SDK の状態を読む典型的な使い方の検証として残した

### CI への組み込み

`.github/workflows/consumer-test.yml` を次のように更新した。

- scheme の存在検査の一覧に `ConsumerSwift5` を追加した
- `Build ConsumerSwift5` step を最初の build step に置いた。`Sora` target は同じ derivedDataPath では最初の build でだけ compile されるため、`consumer-swift5.log` に「Sora は `-swift-version 6`、ConsumerSwift5 は `-swift-version 5`」の compile 行を残すには最初に置く必要がある
- `Check Compiler Settings` を 4 つの log の検査にし、`-warnings-as-errors` と `-default-isolation nonisolated` の検査に `consumer-swift5.log` を加えた。log 全体の `-swift-version 6` の grep は、言語モードが target ごとに決まることを検査できないため削除した
- `Check Language Mode` step を追加し、compile 行の `-module-name` と `-swift-version` の組合せを module ごとに検査する (`Sora` は 6、`ConsumerSwift5` は 5、既存 3 target は 6)
- `Check Deprecation Warning` と `Check No Test-Only Import` の検査内容は変えていない。`ConsumerSwift5` は非推奨 API を使わず、`@testable` と `@preconcurrency` も使わない

`TestConsumers/Swift6Consumer/README.md` の構成表と担当表に `ConsumerSwift5` を追加した。`CHANGES.md` の `## develop` の `### misc` の `[ADD]` の並びの末尾に、担当者行 `- @t-miya` 付きのエントリを追加した。

### 実行した検証と結果 (2026-09-29、Xcode 26.6 / iphoneos26.5 / Swift 6.3.3)

- `rm -rf build/consumer` の後に `make consumer-build SCHEME=ConsumerSwift5`: **BUILD SUCCEEDED**。`-module-name ConsumerSwift5 ` の compile 行 (SwiftDriver / Swift-Compilation / Swift-Compilation-Requirements の 3 行) は `-swift-version 5` で `-default-isolation nonisolated -warnings-as-errors` が付く。`-module-name Sora ` の compile 行は `-swift-version 6` と `-suppress-warnings` のままで `-warnings-as-errors` を含まない。診断は 0 件
- `make consumer-build SCHEME=ConsumerCore` / `ConsumerUI` / `ConsumerLegacy`: 3 scheme とも **BUILD SUCCEEDED**。`-module-name <target> ` の compile 行は 3 target とも `-swift-version 6`。診断は 0 件 / 0 件 / 12 件 (ConsumerLegacy の 12 件はすべて非推奨 API の warning)
- `make consumer-check-negative`: `core-sendable-capture.swift` (`SendableClosureCaptures`) と `ui-isolated-conformance.swift` (`IsolatedConformances`) の 2 件が期待どおり失敗した
- `.github/workflows/consumer-test.yml` の検査のローカル再現: scheme の存在検査、`Check Compiler Settings`、`Check Language Mode`、`Check Deprecation Warning` (11 symbol)、`Check No Test-Only Import` がすべて成功した
- `make build`: **BUILD SUCCEEDED**。warning 17 件 (すべて非推奨 API) / error 0 件で、`-module-name Sora ` の compile 行に `-swift-version 6 -warnings-as-errors -Wwarning DeprecatedDeclaration` が現れる (`0108` と同じ)
- `make fmt-lint` 成功、`swiftlint lint --strict --cache-path build/swiftlint-cache` は 0 violations / 0 serious (65 file)
- `make api-check-fresh`: 「The committed API baseline matches the current Sora module.」で成功した。公開 API を変えていないため baseline は再生成していない
- 全体テスト: `xcodebuild test-without-building` は検証環境の sandbox で `Pseudo Terminal Setup Error ... Operation not permitted` となり起動できないため、`build-for-testing` (`** TEST BUILD SUCCEEDED **`) と `xcrun simctl spawn <iOS 26.5 の iPhone 17 Pro> .../Agents/xctest <abs path>/SoraTests.xctest` (`SIMCTL_CHILD_DYLD_FRAMEWORK_PATH` を設定) で代替した。**441 件実行 / skip 31 / 失敗 0 件**で基準どおり
  - 最初に iOS 26.0 の Simulator で実行したところ `DummyVideoCapturerTests.testDeinitWithoutStopReleasesCapturer` が signal 6 で abort した。Simulator の runtime が 26.5 の build と一致していなかったためで、iOS 26.5 の Simulator では再現しない (同 suite の 8 件がすべて成功)。CI は `OS=26.5` を指定するため影響しない
- 退行検出: `ConsumerSwift5` の `.swiftLanguageMode(.v5)` を `.v6` に変えると `-module-name ConsumerSwift5 ` の compile 行が `-swift-version 6` になり、`Check Language Mode` が失敗する状態になることを確認した。あわせて global shared mutable state が `MutableGlobalVariable` の error になり **BUILD FAILED** になることも確認した。確認後に `.v5` へ戻し、`git diff` で最終状態を確認した
- `git status --short` / `git diff --stat` で、SDK 側 (`Sora/` / `SoraTests/` / root の `Package.swift` / `Makefile` / `.github/workflows/build.yml`) を変更していないことを確認した

### 残った懸念

- CI の `Check Language Mode` は `Sora` の compile 行が `consumer-swift5.log` に残ることを前提にする。`Build ConsumerSwift5` を最初の build step に置くことで満たしているが、step の順序を変えると `Sora` が再 compile されず step が失敗する。この依存は step のコメントに書いた
- 検証環境では `xcodebuild test` が sandbox の PTY 制約で起動できないため、全体テストは `simctl spawn` の代替経路で確認した。CI は通常の `test-without-building` を使う
- `ConsumerSwift5` は compile だけを検証し、Swift 5 言語モードでの実行時挙動は検証しない (スコープ外)
- `ConsumerSwift5` の source は Swift 6 言語モードでも `MutableGlobalVariable` 以外の診断は出ない。言語モードの差が source に現れるのは global shared mutable state の 1 点であり、`Check Language Mode` の compile 行の検査が主たる gate である
