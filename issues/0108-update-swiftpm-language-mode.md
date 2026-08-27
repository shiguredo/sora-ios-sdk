# SwiftPM manifest を Swift 6 language mode に更新する

- Created: 2026-08-27
- Completed:
- Branch: feature/update-swiftpm-language-mode
- Polished:

## 目的

`Package.swift` を Swift 6 対応の tools version と language mode へ更新し、CI の command-line override ではなく package manifest を SwiftPM consumer の正本にする。

SDK target と downstream consumer が同じ Swift language mode で compile されることを保証する。

## 現状

`Package.swift` は `swift-tools-version: 5.3` で、`swiftLanguageModes` または旧 `swiftLanguageVersions` を指定していない。

`swift package dump-package` では tools version が `5.3.0`、Swift language version が未指定となる。

一方、README は Swift 6 言語モードでビルドしていると説明し、GitHub Actions は `xcodebuild` に `SWIFT_VERSION=6` を渡している。この override は通常の SwiftPM consumer へ伝播しない。

manifest を変更せずに CI だけで Swift 6 を指定すると、SDK repository 内の build と利用者の package resolution / compile condition が一致しない。

## 前提となる issue

- `0107`: Swift 6 consumer fixture と strict concurrency CI を追加する。

加えて、manifest の更新で concurrency warning が一斉に gate されるため、少なくとも次の runtime bug と内部 ownership の対応状況を確認してから着手する。

- `0092` から `0099` の runtime bug
- `0100` から `0106` の内部 concurrency refactor

すべての refactor 完了を機械的な必須条件にはしないが、未完了項目を `@unchecked Sendable` や `@preconcurrency` の追加で隠して manifest 更新だけを通してはならない。

## 設計方針

- `swift-tools-version` を現在の最低開発環境で利用できる `6.x` へ更新する。
- package initializer に `swiftLanguageModes: [.v6]` を明示する。
- manifest API の正確なシグネチャを採用 Xcode の `PackageDescription` で確認する。
- iOS deployment target の `.iOS(.v14)` は維持する。
- target 全体の default actor isolation を MainActor にしない。core API は nonisolated を基本とし、UI 型だけを明示的に MainActor へ隔離する。
- CI の `SWIFT_VERSION=6` は manifest と異なる値が混入していないことを確認する冗長な検査として残してよいが、正本は manifest とする。
- tools version の引き上げにより古い SwiftPM が package を読み込めなくなるため、最低 Xcode version と互換性への影響を README とリリース時の変更履歴で明示する。
- `Package.swift` 内の既存 product、target、binary target、platform、dependency の意味を変更しない。

## 検証方針

モックやスタブは使用しない。

- `swift package dump-package` で tools version と Swift 6 language mode を確認する。
- `0107` の consumer fixture を Xcode 26.2 と最新 26.x で build する。
- SDK target と test target を strict concurrency / warnings-as-errors で build する。
- binary `WebRTC.xcframework` の import と iOS 14 deployment target が維持されることを確認する。
- package product `Sora` と `WebRTC` の名前および依存関係が変わっていないことを確認する。
- API baseline に意図しない削除・変更がないことを確認する。

## 完了条件

- `Package.swift` の tools version が Swift 6 対応の `6.x` であること。
- `swiftLanguageModes: [.v6]` が manifest に明示されていること。
- `swift package dump-package` が tools 6.x と Swift 6 language mode を示すこと。
- iOS 14 deployment target が維持されていること。
- package product、target、binary dependency の構成が意図せず変わっていないこと。
- target 全体を MainActor default にして concurrency 問題を隠していないこと。
- `0107` の consumer fixture が strict concurrency / warnings-as-errors で成功すること。
- Xcode 26.2 と最新 26.x の CI が成功すること。
- 最低 Xcode version と SwiftPM compatibility への影響が利用者向け文書に記載されていること。

## 解決方法
