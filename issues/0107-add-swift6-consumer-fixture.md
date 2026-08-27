# Swift 6 consumer fixture と strict concurrency CI を追加する

- Created: 2026-08-27
- Completed:
- Branch: feature/add-swift6-consumer-fixture
- Polished:

## 目的

SDK 自身の target だけでなく、通常の iOS アプリが外部 package として `Sora` を import した状態で Swift 6 の公開 API を検証する consumer fixture を追加する。

`@testable` と `@preconcurrency` による診断抑止を使わず、strict concurrency warning と意図しない source break を CI で検出できるようにする。

## 現状

`.github/workflows/build.yml` と `.github/workflows/ci.yml` は、`xcodebuild` に `SWIFT_VERSION=6` を渡して SDK scheme と E2E test target をビルドしている。

一方、`SoraTests` の E2E test は 7 ファイルで `@testable @preconcurrency import Sora` を使用している。この構成では、通常の利用者が見る public interface と strict concurrency diagnostic を検証できない。

現在の CI には次の gate がない。

- `@testable` ではない外部 consumer からの import
- `@preconcurrency` を使わない import
- `SWIFT_STRICT_CONCURRENCY=complete`
- concurrency warning を含む warnings-as-errors
- explicit な default actor isolation
- 既存 callback API の source compatibility
- 新しい Sendable / MainActor API の利用例
- API digester または symbol graph による意図しない公開 API 変更の検出

`Package.swift` の language mode 設定も consumer 側から検証されていないため、CI の `SWIFT_VERSION=6` override と実際の package 利用条件が乖離している。

## 設計方針

### consumer fixture

- リポジトリ内に、ローカルの `Sora` package を通常依存として利用する最小 iOS consumer project を追加する。
- fixture は `import Sora` を使用し、`@testable` と `@preconcurrency` を禁止する。
- SDK source を fixture target へ直接含めず、実際の downstream と同じ module boundary を通す。
- fixture 自体に接続先、認証情報、機密情報を必要とする runtime test は含めない。公開 API の compile contract を検証する。

### compile scenario

少なくとも次を別ファイルまたは明確な compile scenario として持つ。

- nonisolated context から core の設定・接続 API を利用する。
- MainActor context から `VideoView` と renderer API を利用する。
- 利用者定義の RPC method、params、result 型を利用する。
- 既存 callback API を利用し、互換 API が引き続き compile できることを確認する。
- immutable snapshot、Sendable event、RPC v2 などの新 API が追加された後、それぞれの利用例を追加する。

### compiler settings

- Swift 6 language mode を明示する。
- `SWIFT_STRICT_CONCURRENCY=complete` を明示する。
- `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` を有効にする。
- core API の検証では default actor isolation を `nonisolated` として明示し、target 全体を MainActor にすることで問題を隠さない。
- UI scenario だけを `@MainActor` に隔離する。

### GitHub Actions

- `.github/workflows/build.yml` に consumer fixture 専用 step または job を追加する。
- iOS / Xcode が必要なため `macos-26` runner を使用する。`ubuntu-slim` は UIKit と iOS SDK を利用できないため採用しない。
- Xcode 26.2 と、runner 上で利用可能な最新 26.x の両方を検証する。
- checkout は既存の GitHub 公式 `actions/checkout` を利用し、新しい外部 action は追加しない。
- compile fixture には E2E 用 secret を渡さない。
- 現行 SDK build と consumer build の失敗を別 step にし、どちらの契約が壊れたか分かるようにする。

### 公開 API baseline

- API digester または symbol graph の baseline を保存し、意図しない公開 API の削除・変更を検出する。
- intentional な API 追加や deprecation の baseline 更新手順を日本語コメントまたは開発文書に記載する。
- Swift toolchain の違いによる機械的差分を抑えるため、baseline を生成する Xcode version を固定する。

## スコープ外

- `Package.swift` の tools version と language mode の変更は `0108` で扱う。
- E2E test から既存の `@preconcurrency import Sora` を撤去する作業は別 issue とする。
- Thread Sanitizer を利用した runtime stress test は別 issue とする。
- 実 Sora への接続試験は既存 E2E workflow の責務とする。

## テスト方針

モックやスタブは使用しない。

- fixture は実際のローカル package product `Sora` に依存して compile する。
- Xcode 26.2 と最新 26.x の両方で、clean build を実行する。
- strict concurrency と warnings-as-errors を無効にした場合だけ通るコードを fixture に入れない。
- public API baseline を意図的に変更した確認用 branch で、CI が差分を検出できることを一度確認する。
- fixture の各 scenario には、どの public concurrency contract を検査するかを日本語コメントで明記する。

## 完了条件

- 通常の iOS consumer project がリポジトリ内に存在すること。
- fixture が `@testable` と `@preconcurrency` を使用していないこと。
- `SWIFT_STRICT_CONCURRENCY=complete` と warnings-as-errors で fixture が build できること。
- core scenario の default actor isolation が `nonisolated` であること。
- UI scenario が明示的に MainActor で検証されること。
- 既存 callback API と新しい Swift 6 API の compile scenario を追加できる構造であること。
- Xcode 26.2 と最新 26.x の CI が存在すること。
- consumer fixture に secret が渡されていないこと。
- GitHub 公式または利用実績のない外部 action を新規追加していないこと。
- 公開 API baseline の検査と更新手順が用意されていること。
- 追加した CI と既存 CI がすべて成功すること。

## 解決方法
