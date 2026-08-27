# sora-ios-sdk-quickstart の Swift 6 暫定対応を SDK の本対応へ置き換える

- Created: 2026-08-27
- Completed:
- Branch: feature/update-quickstart-swift6-native-support
- Polished:

## 目的

sora-ios-sdk の Swift 6 本対応(issue 0107、0108 など)が完了した後、sora-ios-sdk-quickstart に残っている暫定対応を撤去し、SDK が提供する本対応の API を使う形へ置き換える。

quickstart は SDK の最小利用例として公開されており、暫定対応(`@preconcurrency import Sora`、`nonisolated(unsafe)` によるファイルスコープクロージャー)が長く残ると、利用者に「この暫定対応が必要」と誤った理解をさせ、正しい Swift 6 での SDK 利用イメージを損なう。

## 現状

sora-ios-sdk-quickstart は Swift 6 言語モード対応時に次の暫定対応を行っている。

- `@preconcurrency import Sora`(`SoraQuickStart/ViewController.swift` 先頭)
- `nonisolated(unsafe) private let soraConnectHandler`(`SoraQuickStart/ViewController.swift`)
  - `Sora.shared.connect()` のハンドラクロージャーを MainActor 隔離から切り離すため、ファイルスコープで事前生成している
- `nonisolated(unsafe) private weak var _currentViewController`(`SoraQuickStart/ViewController.swift`)
  - 接続完了ハンドラから取得・保持する ViewController の参照渡しに使用している
- `nonisolated fileprivate func handleConnectCompletion` / `nonisolated private func _handleConnectCompletion` によるスレッド跨ぎ
- `connectionQueue`(DispatchQueue)による接続処理の直列化
- 既存 issue の対応コミット:
  - "Sora.shared.connect() のハンドラクロージャが @MainActor 隔離を継承する問題を修正する"(79a255f)
  - "Enable Swift 6 language mode"(f8961b2)

一方、sora-ios-sdk では Swift 6 本対応として次の issue が起票済み。

- `0107`: Swift 6 consumer fixture と strict concurrency CI
- `0108`: SwiftPM manifest を Swift 6 language mode に更新
- `0109`: Sendable な RPC API
- `0110`: executor 契約を持つ Sendable event API
- `0120`: Sendable な statistics snapshot API
- `0122`: legacy VideoRenderer API の削除
- `0123`: immutable な公開 value type への Sendable 準拠

## 設計方針

SDK 側で次のいずれかが実現された後の段階で、対応を開始する。

1. `MediaChannel` / `MediaStream` / コールバック型が Sendable 化され、`@preconcurrency import` が不要になった
2. Sendable event API(0110)など、境界を越える値を deep Sendable な型で扱う新 API が提供された

そのうえで、quickstart 側の対応は次の方針とする。

- `@preconcurrency import Sora` を通常の `import Sora` へ戻す
- ファイルスコープの `nonisolated(unsafe)` クロージャー(`soraConnectHandler`、`_currentViewController`)を撤去し、SDK の本対応 API をそのまま使う
- `nonisolated` を付けた機能(`handleConnectCompletion` 等)を見直し、SDK の API に合わせた形へ修正する
- 暫定対応を取り除いた後も、Swift 6 言語モードでビルド・実機確認ができること

quickstart は SDK の最小利用例として提供されている。そのため、SDK 側の本対応を反映した最小の利用例を示すことが、この issue の最大の目的である。

## 完了条件

- `@preconcurrency import Sora` が quickstart から撤去される
- `nonisolated(unsafe)` によるファイルスコープクロージャー(`soraConnectHandler`、`_currentViewController`)が撤去される
- `nonisolated` を付けた機能の見直しが完了し、SDK の正しい利用例になっている
- quickstart が Swift 6 言語モードでビルドでき、実機で接続・切断ができること

## スコープ外

- この issue は sora-ios-sdk 本体の Swift 6 対応を含まない
- sora-ios-sdk-samples の対応は 0124 で扱う
- SDK 側の Swift 6 対応(0092-0123)それ自体の進行管理は SDK 側 issue で扱う

## 参考

- sora-ios-sdk の issue 0092-0123( Swift 6 本対応のロードマップ)
