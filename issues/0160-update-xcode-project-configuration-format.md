# sora-ios-sdk-quickstart と sora-ios-sdk-samples の Xcode プロジェクト設定ファイル形式を更新する

- Created: 2026-09-17
- Completed: {YYYY-MM-DD}
- Branch: feature/update-xcode-project-configuration-format
- Polished: {YYYY-MM-DD}

## 目的

Apple は Xcode 27.2 以降で、Xcode プロジェクトの設定ファイルに、従来の property list 形式の `.pbxproj` に代わる、階層構造を持つ JSON 形式の `.xcproj` を利用できるようにしている。

Sora iOS SDK の利用例である `sora-ios-sdk-quickstart` と `sora-ios-sdk-samples` も JSON 形式へ移行し、プロジェクト設定の差分を確認しやすく、設定変更を安全にレビューできる状態にする。

## 現状

両リポジトリの Xcode プロジェクトは、現在も `.xcodeproj` 内の `project.pbxproj` を利用している。

- `sora-ios-sdk-quickstart/SoraQuickStart.xcodeproj/project.pbxproj`
  - `SoraQuickStart` ターゲットと `Sora` / `WebRTC` / `SwiftLintPlugins` の Swift Package 依存関係を定義している
  - プロジェクトの `objectVersion` は `54`
- `sora-ios-sdk-samples/SamplesApp/SamplesApp.xcodeproj/project.pbxproj`
  - `SamplesApp` ターゲットと `Sora` / `WebRTC` / `SwiftLintPlugins` の Swift Package 依存関係を定義している
  - `PBXFileSystemSynchronizedRootGroup` によるファイルシステム同期グループを利用している
  - プロジェクトの `objectVersion` は `70`

また、両リポジトリの次のファイルは Xcode 26.2 を前提にしている。

- `sora-ios-sdk-quickstart/.github/workflows/build.yml`
- `sora-ios-sdk-quickstart/README.md`
- `sora-ios-sdk-samples/.github/workflows/build.yml`
- `sora-ios-sdk-samples/README.md`

Apple の説明では、`.xcproj` は Xcode 27 以降で利用できる。プロジェクト設定ファイルだけを JSON 形式へ移行して Xcode 26.2 のままにすると、現在のシステム条件と実際にプロジェクトを開ける Xcode の条件が一致しなくなる。

## 設計方針

- Apple の手順に従い、Xcode の Project navigator でプロジェクトを選択し、File inspector の Project Document にある Project Format を JSON に変更する
- 変換後も `.xcodeproj` のディレクトリは維持し、内部の `project.pbxproj` を `project.xcproj` へ置き換える
- `SoraQuickStart` / `SamplesApp` のターゲット、スキーム、ソース・リソースの参照、Swift Package 依存関係、ビルド設定、デプロイメントターゲット、Samples のファイルシステム同期グループを維持する
- 変換作業は Xcode 27.2 以降で行い、変換後の利用条件を `.xcproj` に対応する Xcode 27 以降へ更新する
- 両リポジトリの GitHub Actions と README の Xcode / iOS SDK 条件を、採用する Xcode 27 系のバージョンへ合わせる
- アプリのソースコードや Sora iOS SDK の API 利用方法は変更しない

## 完了条件

- `sora-ios-sdk-quickstart/SoraQuickStart.xcodeproj/project.pbxproj` が削除され、同じプロジェクト内に `project.xcproj` が追加されていること
- `sora-ios-sdk-samples/SamplesApp/SamplesApp.xcodeproj/project.pbxproj` が削除され、同じプロジェクト内に `project.xcproj` が追加されていること
- Xcode 27.2 以降で両プロジェクトを開けること
- 両プロジェクトで既存の `SoraQuickStart` / `SamplesApp` スキームを利用した Release ビルドが成功すること
- Swift Package 依存関係、ターゲット、デプロイメントターゲット、Swift version、ファイル参照が変換前と同じ意味を保っていること
- 両リポジトリの GitHub Actions が、`.xcproj` を扱える Xcode 27 系と対応する iOS SDK で成功すること
- 両リポジトリの README と変更履歴に、プロジェクト形式の変更と Xcode の利用条件が反映されていること

## 解決方法

- `sora-ios-sdk-quickstart/SoraQuickStart.xcodeproj` を Xcode 27.2 以降で開き、Project Format を JSON に変更して `project.xcproj` を生成する
- `sora-ios-sdk-samples/SamplesApp/SamplesApp.xcodeproj` も同じ手順で JSON 形式へ変更し、ファイルシステム同期グループと Swift Package 依存関係が維持されていることを確認する
- 変換前後のプロジェクト設定を比較し、ターゲット、スキーム、ビルド設定、パッケージ依存関係、ファイル参照に意図しない変更がないことを確認する
- 両リポジトリの `.github/workflows/build.yml` の Xcode と SDK の指定を更新する
- 両リポジトリの `README.md` に記載された Xcode のシステム条件と、`CHANGES.md` の変更履歴を更新する
- 各リポジトリで `xcodebuild` による Release ビルドと `make fmt-lint` を実行する

## 参考

- [Updating your Xcode project configuration file format](https://developer.apple.com/documentation/xcode/updating-your-xcode-project-configuration-file-format)
