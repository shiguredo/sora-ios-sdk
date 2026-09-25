# `SoraTests` target を warnings-as-errors にする

- Created: 2026-09-25
- Completed: {YYYY-MM-DD}
- Priority: Low
- Branch: feature/update-soratests-warnings-as-errors
- Polished: {YYYY-MM-DD}

## 目的

`SoraTests` target の warnings-as-errors gate を `Package.swift` の manifest から有効にし、test target の警告を恒久的に検出できるようにする。

`Sora` target には `0108` が同じ gate を入れる。test target 側の gate は `0108` の検証方針と `0155` の前提が `0118` に委譲しており、`0118` の旧記述も同じ gate を対象にしていた。`0118` は concurrency 診断抑止の除去に専念するため、本 issue が引き取る。

## 現状

- `Package.swift` は `swift-tools-version:5.3` で、`SoraTests` target に `swiftSettings` は無い。
- `.github/workflows/e2e-test.yml` の `build-for-testing` は `SWIFT_VERSION=6` のみを指定しており、warnings-as-errors は指定していない。
- `build-for-testing` に `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` を追加する方式は使えない。この build setting は scheme 内の全 target に効くため、`Sora` target が先に落ちる (2026-09-25 の Xcode 26.6 / Swift 6.3.3 での実測で 22 error。`0113` が扱う retroactive conformance、後方互換のために残している非推奨 API の利用、`Sora/ConnectionTimer.swift` などの `#SendableClosureCaptures` を含む)。test target だけを gate するには manifest の target 個別の `swiftSettings` を使う (`0107` の consumer package と同じ方式)。
- 2026-09-25 に `SoraTests` の全ファイルを `-swift-version 6` で型検査した実測は 44 warning / 0 error である。このうち concurrency の 24 件は `0118` が解消し、本 issue の gate を妨げる concurrency 以外の 20 件は次のとおり。
  - 非推奨 API 10 (ConfigurationTests 6、PeerChannelConnectEncodingTests 2、ConnectionConfigurationSnapshotTests 2)
  - 未使用の capture 4 (SendonlyE2ETests 3、RpcE2ETests 1)
  - weak 変数 3 (StreamFrameOwnerTests 2、ConnectionTimerLifecycleTests 1)
  - 未使用の戻り値 2 (DummyAudioDeviceTests の `setHardMute`)
  - 未使用の値 1 (RpcE2ETests)
- `SwiftSetting.treatAllWarnings(as:)` と `treatWarning(_:as:)` は PackageDescription 6.2 以降でしか使えない (Xcode 26.6 の PackageDescription で確認)。`0108` の tools version 6.3 への更新が前提になる。

## 前提となる issue

- `0121` → `0118` → `0108` → 本 issue の順で実施する。`0121` は `pcmGenerator` を `@Sendable` にするため `0118` より先、`0118` は `SoraTests` の concurrency 診断を解消するため `0108` の gate 有効化より先、`0108` は `swift-tools-version` を 6.3 に上げるため本 issue の `swiftSettings` 追加より先である。
- `0108`: `swift-tools-version` を 6.3 に上げ、`swiftLanguageModes` と `Sora` target の gate を manifest に追加する。本 issue は同じ `Package.swift` を編集するため、`0108` の後に実施する。`0108` の検証方針にある「test target の gate の本対応は `0118` の管轄」は本 issue を指すように更新する必要がある。
- `0118`: `SoraTests` の concurrency 診断 (24 件) を解消する。gate を先に有効にすると concurrency 診断で build が落ちるため、`0118` の後に実施する。
- `0141` (open): `SignalingChannel` を WebSocket 接続管理に純化する。本 issue が `weak var` を直す `SoraTests/ConnectionTimerLifecycleTests.swift` を 0141 も変更対象にしているため、実施順序を調整する (`0057` も `SoraTests/StreamFrameOwnerTests.swift` を変更対象にしているが、優先度 Low のため競合した時点で調整する)。

## 設計方針

- `Package.swift` の `SoraTests` target に `swiftSettings` を追加する。`.treatAllWarnings(as: .error)` を先、`.treatWarning("DeprecatedDeclaration", as: .warning)` を後に書く。SwiftPM は宣言順に `-warnings-as-errors` と `-Wwarning` を並べるため、逆順にすると deprecation が error になり build できない (`0107` の `ConsumerLegacy` と同じ方式)。
- `DeprecatedDeclaration` を warning のまま残すのは、後方互換検証のために非推奨 API を意図的に参照しているテストがあり、`0138` がそれを対象外としているためである。
- gate で error になる concurrency 以外の警告を解消する。
  - `StreamFrameOwnerTests.swift` と `ConnectionTimerLifecycleTests.swift` の `weak var` は書き換えていないため `let` にする。
  - `DummyAudioDeviceTests.swift` の `setHardMute` の戻り値は `_ =` で捨てるか assert に使う。
  - `SendonlyE2ETests.swift` と `RpcE2ETests.swift` の未使用の `[self]` capture を削除する。
  - `RpcE2ETests.swift` の `testRPCRaceWithDisconnectTerminatesAll` にある `guard let sendonlyChannel` は値を利用していないため `guard sendonlyChannel != nil` にする (`testRequestSimulcastRid` の同名の束縛は `waitForOutboundR0AndR2` へ渡して使うため変更しない)。
- 公開 API、target 構成、iOS deployment target、依存関係を変更しない。

## スコープ外

- `Sora` target の warnings-as-errors gate と、`Sora` target に残る concurrency 警告 (`0108` / `0113` / `0155` が扱う)。
- 非推奨 API を参照しているテストの書き換え (`0138` が対象外としている)。
- `SoraTests` の concurrency 診断の解消 (`0118` が扱う)。

## 変更対象

- `Package.swift`: `SoraTests` target の `swiftSettings` の追加
- `SoraTests/StreamFrameOwnerTests.swift` / `SoraTests/ConnectionTimerLifecycleTests.swift`: `weak var` の `let` 化
- `SoraTests/DummyAudioDeviceTests.swift`: `setHardMute` の未使用の戻り値の解消
- `SoraTests/SendonlyE2ETests.swift` / `SoraTests/RpcE2ETests.swift`: 未使用の `[self]` capture と未使用の値の解消 (`0118` の変更後もこの警告は残るため、行番号がずれた状態で実測して該当箇所を消す)
- `issues/0108-update-swiftpm-language-mode.md` / `issues/0155-refactor-connect-error-closure-capture.md`: test target の gate の委譲先を本 issue に更新する (`0108` の `## 前提となる issue` にある `0118` の記述と検証方針の「test target の gate の本対応は `0118` の管轄」、`0155` の `## 前提となる issue` の「`0118`: test target の strict concurrency ゲート」)
- `CHANGES.md`: `## develop` の `### misc` に `[UPDATE]` で「`SoraTests` target を warnings-as-errors にする」を追記し、公開 API と利用者の挙動の変更がないことを補足行に書く (担当者行 `- @ユーザー名` を含める)

## テスト方針

モックやスタブは使用しない。

- `0108` と `0118` の完了後、fresh な checkout で `.github/workflows/e2e-test.yml` の `build-for-testing` と同じ invocation (`xcodebuild build-for-testing -scheme Sora-Package -sdk <XCODE_SDK> -derivedDataPath build -destination ... CODE_SIGNING_REQUIRED=NO SWIFT_VERSION=6`) を実行し、`SoraTests` target の `DeprecatedDeclaration` 以外の警告が 0 件であることを確認する。
- compile flags に `-warnings-as-errors` と `-Wwarning DeprecatedDeclaration` が現れることを build ログで確認する (`0107` が consumer package で行っているのと同じ方式。incremental build で compile が省略されると flags が現れないため、fresh な checkout で build する)。
- 非推奨 API を参照しているテストでは deprecation が warning として出続けることを symbol 名で確認する (xcodebuild は diagnostic group 名を出力しないため、件数ではなく symbol 名で判定する)。
- 既存テストがすべて成功することを確認する。

## 完了条件

- `Package.swift` の `SoraTests` target の `swiftSettings` が `.treatAllWarnings(as: .error)`、`.treatWarning("DeprecatedDeclaration", as: .warning)` の順であること。
- fresh な checkout での `xcodebuild build-for-testing` のログに `-warnings-as-errors` と `-Wwarning DeprecatedDeclaration` が現れ、`SoraTests` target の `DeprecatedDeclaration` 以外の警告が 0 件であること。
- 公開 API、target 構成、iOS deployment target、依存関係が変わっていないこと。
- 既存テストがすべて成功すること。
- `0108` と `0155` の test target の gate の委譲先が本 issue に更新されていること。
- `CHANGES.md` の `## develop` の `### misc` に `[UPDATE]` で `SoraTests` target を warnings-as-errors にしたことが追記され、公開 API と利用者の挙動の変更がないことが補足されていること。

## 解決方法
