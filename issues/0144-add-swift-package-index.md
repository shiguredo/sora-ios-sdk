# Swift Package Index に Sora iOS SDK を登録する

- Created: 2026-09-11
- Completed:
- Branch: feature/add-swift-package-index
- Polished: 2026-09-24

## 目的

Swift Package Index に Sora iOS SDK を登録し、Swift Package としての検索・発見性を高める。

## 現状

Sora iOS SDK はリポジトリルートに `Package.swift` を持つ Swift Package として公開されているが、Swift Package Index には未登録である。`https://swiftpackageindex.com/shiguredo/sora-ios-sdk` は 404 を返し、登録を促す案内が表示される。

Swift Package Index の登録条件（<https://swiftpackageindex.com/add-a-package>）との照合結果は以下のとおりであり、本パッケージで対応が必要な未達条件は確認できない。

- パッケージリポジトリが公開されていること（`shiguredo/sora-ios-sdk` は公開され、アーカイブされていない）
- リポジトリルートに有効な `Package.swift` があること
- Swift 5.0 以上で記述されていること（現行は `swift-tools-version: 5.3`）
- セマンティックバージョンのリリースタグが 1 つ以上あること
  - `2026.3.0` があり、`MAJOR.MINOR.PATCH` として解釈できる
- 最新の Swift toolchain で `swift package dump-package` が有効な JSON を出力すること（Swift 6.0.3 で有効な JSON を確認済み）
- 登録 URL がプロトコルと `.git` 拡張子を含むこと（`https://github.com/shiguredo/sora-ios-sdk.git`）
- すべてのパッケージがエラーなくコンパイルできること
  - SPI は Apple 各プラットフォーム（iOS / macOS / tvOS / watchOS）と Linux でビルドを試みるが、ビルドできないプラットフォームは incompatible（グレー）表示になるだけで、掲載自体は可能である
  - `Package.swift` の `platforms` は `.iOS(.v14)` のみで、バイナリターゲット `WebRTC` も iOS 用のスライスのみを含むため、iOS 以外のビルドは成功しない（前述のとおり incompatible 表示になるだけで、iOS 専用パッケージの掲載例は存在する（例: PanModal））

`swift package dump-package` の出力からは、`platforms` が `ios` の `14.0` のみであることと、product `Sora` と `WebRTC`、バイナリターゲット `WebRTC` の構成が読み取れる。

## 設計方針

- <https://swiftpackageindex.com/add-a-package> の「Add Package(s)」から SwiftPackageIndex/PackageList の issue を立て、`https://github.com/shiguredo/sora-ios-sdk.git` を登録する
- iOS 専用パッケージだが、Swift Package Index にはビルド対象プラットフォームを限定する設定は存在しない（Builds FAQ の「Is it possible to hide failing builds for unsupported platforms?」への回答は「Not currently.」）。非対応プラットフォームは incompatible（グレー）表示になるだけであるため、`.spi.yml` は追加しない
- 登録後、Swift Package Index が案内する shields.io バッジ（プラットフォーム互換 / Swift バージョン）を README に追加する

## 完了条件

- `https://swiftpackageindex.com/shiguredo/sora-ios-sdk` がパッケージページとして表示され、Swift Package Index の検索結果でも参照できること
- README に Swift Package Index の shields.io バッジ（プラットフォーム互換 / Swift バージョン）が追加されていること

## 解決方法
