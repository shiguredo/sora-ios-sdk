# SwiftPM manifest を Swift 6 language mode に更新する

- Created: 2026-08-27
- Completed:
- Branch: feature/update-swiftpm-language-mode
- Polished: 2026-09-24

## 目的

`Package.swift` を Swift 6 対応の tools version と language mode へ更新し、CI の command-line override ではなく package manifest を SwiftPM consumer の正本にする。

SDK target と downstream consumer が同じ Swift language mode で compile されることを保証する。

## 現状

`Package.swift` は `swift-tools-version: 5.3` で、`swiftLanguageModes` または旧 `swiftLanguageVersions` を指定していない。

`swift package dump-package` では tools version が `5.3.0`、Swift language version が未指定となる。

一方、README は Swift 6 言語モードでビルドしていると説明し、GitHub Actions は `xcodebuild` に `SWIFT_VERSION=6` を渡している。この override は通常の SwiftPM consumer へ伝播しない。

現行 CI の override により、SDK target と test target は既に Swift 6 言語モード相当で build されている。manifest 更新の直接的な影響は、SwiftPM consumer 側の compile 条件の正本化であり、repository 内の build の言語モードは変わらない（警告を error にする gate の追加は「設計方針」で扱う）。

manifest を変更せずに CI だけで Swift 6 を指定すると、SDK repository 内の build と利用者の package resolution / compile condition が一致しない。

## 前提となる issue

- `0107`: Swift 6 consumer package と strict concurrency CI を追加する。
- `0118`: E2E テストの concurrency 診断抑止を除去する。
- `0157` (実装済み): `SoraError.rpcServerError(detail:)` の associated value に出ていた Swift 6 の concurrency 警告を解消した。検証方針の「SDK target を strict concurrency / warnings-as-errors で build する」は、`0157` の実装で警告が解消したため以降この検証を有効にする。

加えて、manifest の更新で concurrency warning が一斉に gate されるため、少なくとも次の runtime bug と内部 ownership の対応状況を確認してから着手する。

- `0092` から `0099` の runtime bug
- `0100` から `0106` の内部 concurrency refactor

SDK target を warnings-as-errors で build するには、次の open issue が残す警告の解消が前提になる。

- `0113`: WebRTC enum の retroactive conformance（`Sora/Extensions/RTC+Description.swift` / `Sora/DataChannel.swift` / `Sora/PeerChannel.swift` の 6 型）。`0113` 自身が「`0108` で SDK target を warnings-as-errors にすると失敗要因になる」と記述している。
- `0155`: `Sora.connect` の設定エラー通知経路の `#SendableClosureCaptures` 警告。
- `0157`: `SoraError.rpcServerError` の `RPCErrorDetail`（non-Sendable）による診断。`0157` が本 issue の `## 前提となる issue` への追加を要求している。

すべての refactor 完了を機械的な必須条件にはしないが、未完了項目を `@unchecked Sendable` や `@preconcurrency` の追加で隠して manifest 更新だけを通してはならない。

## 設計方針

- `swift-tools-version` を `6.3` へ更新する。最低開発環境は README のシステム条件の Xcode 26.6 以降であり、Xcode 26.6 が同梱する Swift 6.3.3 の SwiftPM が読み取れる tools version の上限が 6.3 である。最低 Xcode を 26.6 に上げた `0169` により、tools version の引き上げで新たにサポート対象外になる consumer はいない。実装時は `swift package --version` と `PackageDescription` で上限と manifest API を再確認する。
- package initializer に `swiftLanguageModes: [.v6]` を明示する。
- manifest API の正確なシグネチャを採用 Xcode の `PackageDescription` で確認する。
- iOS deployment target の `.iOS(.v14)` は維持する。
- target 全体の default actor isolation を MainActor にしない。core API は nonisolated を基本とし、UI 型だけを明示的に MainActor へ隔離する。
- CI の `SWIFT_VERSION=6` は manifest と異なる値が混入していないことを確認する冗長な検査として残してよいが、正本は manifest とする。
- SDK target の warnings-as-errors を manifest から有効にし、xcodebuild / `swift build` / consumer からの依存 build のすべてで gate にする。`Package.swift` の Sora target の `swiftSettings` に `.treatAllWarnings(as: .error)` を追加し、続けて `.treatWarning("DeprecatedDeclaration", as: .warning)` を書く（宣言順に compiler flag が並ぶため、逆順にすると deprecation が error になる。`0107` の ConsumerLegacy と同じ方式）。この除外は、`0138` が対象外とする iOS SDK 由来の deprecation 警告と、`0072` が許容する iOS 18 の deprecation 警告を error にしないためである。concurrency 系の警告は error になり、`0113` / `0155` / `0157` による残存警告の解消が前提になる。
- tools version の引き上げにより古い SwiftPM が package を読み込めなくなるため、最低 Xcode version と互換性への影響を README と `skills/sora-ios-sdk/SKILL.md` とリリース時の変更履歴で明示する。`SKILL.md` の「Swift 6 と並行性」と「現状の制約」は manifest の 5.3 を前提に書かれており、更新しないと実装後の状態と矛盾する。
- `Package.swift` 内の既存 product、target、binary target、platform、dependency の意味を変更しない。

## 検証方針

モックやスタブは使用しない。

- `swift package dump-package` で tools version と Swift 6 language mode を確認する。
- `0107` の consumer package を Xcode 26.6 の 1 leg で build する。
- SDK target を strict concurrency / warnings-as-errors（`.treatAllWarnings(as: .error)`）で build し、concurrency 系の warning が 0 件であることを確認する。この build 条件は「設計方針」のとおり manifest から有効になり、CI を含む全 build 経路の恒久 gate になる。
- test target は現行 CI 相当で build が成功することを確認する。test target の strict concurrency / warnings-as-errors gate の本対応は `0118` の管轄とする。
- binary `WebRTC.xcframework` の import と iOS 14 deployment target が維持されることを確認する。
- package product `Sora` と `WebRTC` の名前および依存関係が変わっていないことを確認する。
- API baseline に意図しない削除・変更がないことを確認する。

## 変更対象

- `Package.swift`: `swift-tools-version` と `swiftLanguageModes` の追加、Sora target の `swiftSettings`（warnings-as-errors と `DeprecatedDeclaration` の除外）
- `.github/workflows/build.yml` / `Makefile`: `SWIFT_VERSION=6` は冗長な検査として残す（Sora target の warnings-as-errors は manifest から有効になるため変更しない）
- `README.md` / `skills/sora-ios-sdk/SKILL.md`: 最低 Xcode version と SwiftPM compatibility への影響、manifest が正本であること
- `CHANGES.md`: `## develop` への追記（`shiguredo-changelog` に従う）

## 完了条件

- `Package.swift` の `swift-tools-version` が `6.3` であること。
- `swiftLanguageModes: [.v6]` が manifest に明示されていること。
- `swift package dump-package` が tools `6.3` と Swift 6 language mode を示すこと (`swiftLanguageVersions` に `["6"]` が現れることが期待されるが、キー名と値の形式は採用 Xcode の `PackageDescription` が出力する JSON で確認する)。
- iOS 14 deployment target が維持されていること。
- package product、target、binary dependency の構成が意図せず変わっていないこと。
- target 全体を MainActor default にして concurrency 問題を隠していないこと。
- Sora target が strict concurrency / warnings-as-errors（concurrency 系 warning 0 件）で build でき、`Package.swift` の Sora target に `.treatAllWarnings(as: .error)` と `.treatWarning("DeprecatedDeclaration", as: .warning)` がこの順であること。
- `0107` の consumer package が strict concurrency / warnings-as-errors で成功すること。
- Xcode 26.6 の 1 leg の CI が成功すること。
- 最低 Xcode version と SwiftPM compatibility への影響が `README.md` と `skills/sora-ios-sdk/SKILL.md` に記載されていること。

## 解決方法
