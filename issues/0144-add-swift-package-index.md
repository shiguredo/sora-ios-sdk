# Swift Package Index に Sora iOS SDK を登録する

- Created: 2026-09-11
- Completed:
- Branch: feature/add-swift-package-index
- Polished:

## 目的

Swift Package Index に Sora iOS SDK を登録し、Swift Package としての検索・発見性を高める。

## 現状

Sora iOS SDK はリポジトリルートに `Package.swift` を持つ Swift Package として公開されているが、Swift Package Index には未登録である。

Swift Package Index の登録条件（<https://swiftpackageindex.com/add-a-package>）を確認した範囲では、以下を満たしている。

- 公開リポジトリであること
- リポジトリルートに有効な `Package.swift` があること
- Swift 5.0 以上であること
- セマンティックバージョンのリリースタグが 1 つ以上あること
  - `2026.3.0` 形式のリリースタグがあり、セマンティックバージョンとして解釈できる
- `swift package dump-package` が有効な JSON を出力すること
  - `swift package dump-package` が有効な JSON を出力することを確認済み

`Package.swift` の `platforms` は `.iOS(.v14)` のみで、バイナリターゲット `WebRTC` も iOS 用のスライスのみを含む。

## 設計方針

- <https://swiftpackageindex.com/add-a-package> から `https://github.com/shiguredo/sora-ios-sdk.git` を登録する
- iOS 専用パッケージのため、Swift Package Index のビルド対象プラットフォームを iOS に限定する設定（`.spi.yml`）が必要かを確認し、必要なら追加する
- 登録後、Swift Package Index が案内する shields.io バッジ（プラットフォーム互換 / Swift バージョン）を README に追加する

## 完了条件

- Sora iOS SDK が Swift Package Index に登録され、パッケージページと検索結果で参照できること
- 必要に応じて `.spi.yml` と README のバッジが追加されていること

## 解決方法
