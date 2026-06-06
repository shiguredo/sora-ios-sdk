# iOS SDK の NOTICE ファイルの要否を確認する

- Priority: Low
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/add-notice-file（NOTICE 作成が必要と判断した場合のみ。不要の場合はブランチ不要）
- Polished: 2026-06-06

## 目的

Sora iOS SDK が依存するライブラリ（WebRTC.xcframework）のライセンス条件を確認し、NOTICE ファイルの作成が法的に必要かどうかを判断する。必要と判断した場合はリポジトリルートに NOTICE ファイルを作成する。

## 優先度根拠

ライセンス義務の不履行はリポジトリ利用者・配布先のアプリに法的リスクをもたらす可能性があり、対応すべき問題である。ただし現在確認されたライセンス違反はなく緊急性はないため Low とする。

## 現状

リポジトリルートに NOTICE ファイルが存在しない。THANKS ファイルはコントリビューター一覧として存在するが、Apache License の NOTICE とは別物であり NOTICE の代替にはならない。本リポジトリ自体は Apache License 2.0 を採用している（`LICENSE` ファイル参照）。

`Package.swift` に記載されている依存は以下の 2 つのみである。

- **`WebRTC.xcframework`**（m148.7778.7.0）: `shiguredo-webrtc-build` が提供するバイナリターゲット。libwebrtc（BSD ライセンス）と、その内部に含まれる BoringSSL・Opus・libyuv・OpenH264・libvpx・libaom 等の多数のサードパーティライブラリをバンドルしている
- **`SwiftLintPlugins`**: SPM のビルドプラグインとして動作し、ビルド時のみ使用されてバイナリには含まれない。SPM のビルドプラグイン依存は下流プロジェクトへ伝播しないため、SDK 利用者の配布物にも含まれない。ライセンス表示の対象外

本調査には 2 つの独立した法的義務が関わる。

1. **Apache License 2.0 第 4 条 (d) の伝播義務**: 「NOTICE ファイルを含む著作物を配布する場合、そのファイルの内容を引き継ぐ義務」。これは NOTICE ファイルの「作成義務」ではなく「伝播義務」であり、libwebrtc やその依存ライブラリが NOTICE ファイルを持っているかどうかを確認することが主眼
2. **BSD ライセンスの著作権表示義務**: libwebrtc 本体および内包するサードパーティライブラリの多くは BSD 系ライセンスを採用している。BSD 系ライセンスは変種（2-clause・3-clause 等）によって条件が異なるが、多くは「再配布時に著作権表示と免責事項を含めること」を独立して要求する。Apache 第 4 条 (d) の有無にかかわらず、BSD 系ライセンスの帰属表示要件を満たしているかどうかの確認が必要

## 設計方針

### 調査手順

1. **shiguredo-webrtc-build リポジトリの確認**: `https://github.com/shiguredo-webrtc-build/webrtc-build` の m148.7778.7.0 タグを参照し、NOTICE ファイルまたは同等の帰属表示ファイルが含まれているかを確認する。`WebRTC.xcframework` 内（xcframework 展開後の `Headers/` / `Modules/`）にも NOTICE / LICENSE が梱包されているかを確認する。確認方法: リリースページからリリースアーカイブ（.zip）をダウンロードして手動展開するか、`swift package resolve` 実行後に `.build/artifacts/` 以下のバイナリターゲット展開先を参照する（バイナリターゲットは `.build/checkouts/` ではなく `.build/artifacts/` に展開される点に注意。見つからない場合は `find .build -name '*.xcframework' 2>/dev/null` で探すこと）
2. **WebRTC 本家の NOTICE・サードパーティライブラリ確認**: `https://webrtc.googlesource.com/src` の NOTICE / LICENSE ファイルを確認する。調査範囲はすべての `third_party/` ではなく、shiguredo-webrtc-build の m148.7778.7.0 リリースノート・DEPS ファイルに明記されているライブラリに限定する（全 `third_party/` は 100 を超えるため網羅は現実的でない）。各ライブラリの `README.chromium`（ライセンス種別・著作権表示が記載されている）を確認し、BSD 系については 2-clause・3-clause・4-clause 等の変種を識別した上で著作権表示条件の有無を判断すること（変種によって条件が異なる）
3. **時雨堂の他 SDK の NOTICE ファイル参照**: `sora-cpp-sdk`・`sora-unity-sdk`・`sora-android-sdk` など GitHub org `shiguredo` 配下で NOTICE ファイルを持つリポジトリがあればその記載内容を参考にし、iOS SDK に転用できる記載を洗い出す
4. **結論の記録と close**: 調査結果（必要・不要のどちらであっても）を本 issue の `## 解決方法` に記載する。close 手順は `git mv issues/0066-investigate-notice-file.md issues/closed/0066-investigate-notice-file.md`。不要と判断した場合は @voluntas の承認を得てから close すること（ライセンス義務の判断であるため）

### 必要・不要の判定基準

調査手順 1〜3 の結果をもとに、以下の基準で判定する。

- **必要**: libwebrtc またはその依存ライブラリの NOTICE ファイルが xcframework 内に梱包されておらず、かつ SDK 利用者が帰属表示を受け取れる状態になっていない場合。または BSD 系ライセンスの著作権表示条件が満たされていない場合
- **不要**: libwebrtc の NOTICE ファイルおよび BSD 系ライブラリの著作権表示が xcframework 内に既に梱包されており、SDK 利用者が xcframework を受け取った時点で帰属表示も受け取れる状態になっている場合

「不要」の場合でも「SDK ユーザーがどこで帰属表示を受け取っているか」を `## 解決方法` に明記すること。「BSD だから不要」という根拠のない結論は不可。

### NOTICE ファイルが必要と判断した場合

`feature/add-notice-file` ブランチで作業する。コミット・PR は CLAUDE.md の規約に従い、全テストが通った状態で PR を作成して @voluntas のレビューを依頼すること。リポジトリルートに `NOTICE` ファイルを作成し、以下を記載する。

- libwebrtc のライセンス表示（BSD ライセンス本文または帰属表示）
- libwebrtc が内包するサードパーティライブラリのうちライセンス表示義務があるものの記載

なお、本リポジトリ自体の帰属表示を NOTICE に記載することは義務ではなく任意である（Apache License 2.0 第 4 条 (d) は他者の NOTICE を引き継ぐ義務であり、自社の帰属表示を NOTICE に書く義務ではない）。

NOTICE エントリの記載フォーマットは調査手順 1〜2 で確認した実際の NOTICE 文面に従うこと。以下は参考として Apache NOTICE の一般的な様式を示すが、実際の表記は libwebrtc の NOTICE を優先すること。

```
Copyright (c) <year> The WebRTC project authors. All Rights Reserved.
```

### NOTICE ファイルが不要と判断した場合

「不要」と判断した根拠を `## 解決方法` に記載して close する。ライセンス義務の判断であるため、close 前に @voluntas の承認を得ること。記載内容は以下のレベルで明記すること。

- 調査したライブラリ名と各ライセンス種別
- 表示義務なしの根拠（例: 「libwebrtc は shiguredo-webrtc-build の xcframework 内に著作権表示が梱包されており、SDK 利用者は xcframework を受け取った時点で帰属表示も受け取っている」など）
- BSD ライセンスの著作権表示条件をどのように満たしているか（「不要」の場合でも BSD 帰属表示がどこで満たされているかを明記すること。「BSD だから不要」という結論は誤りである点に注意）

NOTICE ファイルは作成しない。CHANGES.md への記載も不要。

## 完了条件

- Apache License 2.0 第 4 条 (d) の伝播義務の有無を確認済みであること
- libwebrtc（m148.7778.7.0）内の BSD ライセンスライブラリの著作権表示義務をどのように満たすかを確認済みであること
- 調査結果（必要・不要どちらの場合も）が `## 解決方法` に記載されていること
- `git mv` で `issues/closed/` に移動済みであること
- 「必要」と判断した場合: NOTICE ファイルがリポジトリルートに作成されており、@voluntas のレビュー承認を得て PR がマージされていること
- 「不要」と判断した場合: 不要である根拠（BSD 帰属表示の充足方法を含む）が `## 解決方法` に記載されており、@voluntas の承認を得て close されていること
- 「必要」と判断し NOTICE ファイルを作成した場合は、`CHANGES.md` の `## develop` セクションの `### misc` に以下を追記すること

```
- [ADD] NOTICE ファイルを追加する
  - @voluntas
```

## 解決方法
