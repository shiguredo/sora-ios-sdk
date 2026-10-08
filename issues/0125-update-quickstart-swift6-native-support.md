# sora-ios-sdk-quickstart の Swift 6 暫定対応を SDK の本対応へ置き換える

- Created: 2026-08-27
- Completed:
- Branch: feature/update-quickstart-swift6-native-support
- Polished: 2026-10-08

## 目的

sora-ios-sdk の Swift 6 本対応 (0110 の Sendable event API など) が sora-ios-sdk 2026.4.0-canary.2 に取り込まれたため、sora-ios-sdk-quickstart に残っている暫定対応を撤去し、SDK が提供する本対応の API を使う形へ置き換える。

quickstart は SDK の最小利用例として公開されており、暫定対応 (`@preconcurrency import Sora`、`nonisolated(unsafe)` によるファイルスコープ宣言) が長く残ると、利用者に「この暫定対応が必要」と誤った理解をさせ、正しい Swift 6 での SDK 利用イメージを損なう。

## 前提

- 変更するのは sora-ios-sdk-quickstart リポジトリで、sora-ios-sdk 本体のコードは変更しない。`Branch:` は sora-ios-sdk-quickstart に切るブランチ名である
- 0110 が追加した `Sora.subscribeEvents(bufferingPolicy:)` と `MediaChannel.subscribeEvents(bufferingPolicy:)` は 2026-10-07 に完了し、sora-ios-sdk 2026.4.0-canary.2 に取り込まれている
- quickstart は SDK を 2026.3.0 に固定している (`SoraQuickStart.xcodeproj/project.pbxproj` の `exactVersion` と `Package.resolved`)。2026.3.0 には購読 API が無いため、先に 2026.4.0-canary.2 へ上げる
- 2026.4.0-canary.2 の `Package.swift` は `swift-tools-version:6.3` のため、SwiftPM で取り込むには Xcode 26.6 以上 (SwiftPM 6.3 以上) が必要になる。quickstart の README のシステム条件と `.github/workflows/build.yml` の Xcode 条件も更新する
- `MediaChannel` / `MediaStream` は `Sendable` ではない状態が維持される (`skills/sora-ios-sdk/SKILL.md` と SDK のドキュメントコメントが明記している)。SDK は `MediaChannel` / `MediaStream` を `Sendable` にするのではなく、値として確定したイベントを配送する購読 API で境界を越える設計を採っている
- 0160 (Xcode プロジェクト設定ファイル形式の更新) が先行した場合は `project.pbxproj` ではなく `project.xcproj` を変更し、Xcode の条件は 0160 の値を維持する

## 変更対象

sora-ios-sdk-quickstart の次のファイル。

- `SoraQuickStart/ViewController.swift` (暫定対応の撤去と購読 API への置き換え)
- `SoraQuickStart.xcodeproj/project.pbxproj` (SDK 依存の `exactVersion`。0160 の実施後は `project.xcproj`)
- `SoraQuickStart.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- `README.md` (システム条件の Xcode と Swift)
- `.github/workflows/build.yml` (`XCODE` と `XCODE_SDK`)
- `CHANGES.md` (SDK バージョン更新)

## 現状

sora-ios-sdk-quickstart は Swift 6 言語モード対応時に次の暫定対応を行っている。すべて `SoraQuickStart/ViewController.swift` にある。

- `@preconcurrency import Sora`
- ファイルスコープの `nonisolated(unsafe) private let soraConnectHandler` (接続完了クロージャー)
  - `Sora.shared.connect()` のハンドラクロージャーを MainActor 隔離から切り離すため、ファイルスコープで事前生成している
- ファイルスコープの `nonisolated(unsafe) private weak var _currentViewController` (ViewController の参照)
  - 接続完了ハンドラから ViewController へ処理を渡すために使用している
- `nonisolated fileprivate func handleConnectCompletion` / `nonisolated private func _handleConnectCompletion` によるスレッド跨ぎ
- Swift 6 言語モードで使用している legacy のハンドラ
  - `Sora.shared.connect(configuration:handler:)` の `handler`
  - `config.mediaChannelHandlers.onAddStream` (受信ストリームへの `videoRenderer` 設定)
  - `config.mediaChannelHandlers.onDisconnect`
  - `config.mediaChannelHandlers.onReceiveSignalingJSON`

暫定対応が入った経緯は sora-ios-sdk-quickstart のコミットで確認できる。

- "Enable Swift 6 language mode" (f8961b2、2026-02-18): `@preconcurrency import Sora` を追加
- "Sora.shared.connect() のハンドラクロージャが @MainActor 隔離を継承する問題を修正する" (79a255f、2026-07-27): ファイルスコープの `nonisolated(unsafe)` 宣言を追加

`connectionQueue` (DispatchQueue) による接続処理の直列化は Swift 6 対応とは無関係で、接続と切断の連打を順次処理するために 2026.1 で入ったもの。本 issue の撤去対象ではない。

SDK 側の Swift 6 本対応の状況は次のとおり。

| issue | 内容 | 状態 |
| --- | --- | --- |
| 0107 | Swift 6 consumer package と strict concurrency CI | closed (2026-09-24) |
| 0108 | SwiftPM manifest を Swift 6 language mode に更新 | closed (2026-09-29) |
| 0109 | Sendable な RPC API | closed (2026-09-30) |
| 0110 | executor 契約を持つ Sendable event API | closed (2026-10-07) |
| 0120 | Sendable な statistics snapshot API | closed (2026-10-06) |
| 0122 | legacy VideoRenderer API の削除 | open |
| 0123 | 公開値型を `Sendable` に対応させる | closed (2026-09-15) |

## 設計方針

SDK 側の前提は充足している。0110 の購読 API が 2026.4.0-canary.2 に取り込まれているため、これを使って暫定対応を置き換える。`MediaChannel` / `MediaStream` の `Sendable` 化は待たない。

- SDK 依存を 2026.4.0-canary.2 へ上げ、README のシステム条件と CI の Xcode を SwiftPM 6.3 (Xcode 26.6 以上) に合わせる
- イベントの受け取りを 0110 の購読 API へ置き換える
  - 接続結果は `Sora.subscribeEvents(bufferingPolicy:)` の `.connected` / `.connectFailed` で受ける。購読は接続前に開始する
  - 受信ストリームは `MediaChannel.subscribeEvents(bufferingPolicy:)` の `.streamAdded` / `.streamRemoved` と `MediaChannel.streams` で `streamId` から解決し、`videoRenderer` を設定する
  - 切断は `.disconnected`、シグナリングは `.signalingReceivedJSON` を使う
  - `MediaChannel` の実体は `Sora.mediaChannels` から取得する
- 購読 API へ置き換えられない箇所が残る場合は、SDK のドキュメントコメントに従い、`@Sendable` を付けたクロージャと `nonisolated(unsafe) let` + `Task { @MainActor in ... }` で隔離を外す。ファイルスコープの `nonisolated(unsafe)` 宣言は使わない
- `@preconcurrency import Sora` を撤去し、通常の `import Sora` へ戻す
- `nonisolated` を付けた関数は、購読 API への置き換え後に不要になったものを削除し、残すものは理由をコメントに書く
- `connectionQueue` による直列化とタイムアウト処理は維持する

quickstart は SDK の最小利用例として提供されている。SDK 側の本対応を反映した最小の利用例を示すことが、この issue の最大の目的である。

## 完了条件

- quickstart が sora-ios-sdk 2026.4.0-canary.2 を利用している (`exactVersion` と `Package.resolved` が 2026.4.0-canary.2)
- `@preconcurrency import Sora` が撤去される。撤去できない場合は、どの API が原因かを特定して記録する
- ファイルスコープの `nonisolated(unsafe)` 宣言 (`soraConnectHandler` クロージャーと `_currentViewController` 変数) が撤去される
- legacy のハンドラ (`connect` の `handler`、`onAddStream`、`onDisconnect`、`onReceiveSignalingJSON`) が 0110 の購読 API の利用例へ置き換わる
- `nonisolated` を付けた関数の見直しが完了し、SDK の正しい利用例になっている
- quickstart が Swift 6 言語モードでビルドでき、実機で接続と切断ができる
- README のシステム条件と `.github/workflows/build.yml` の Xcode が Xcode 26.6 以上 (SwiftPM 6.3 以上) に更新される
- CHANGES.md に SDK バージョン更新が記載される

## スコープ外

- sora-ios-sdk 本体の Swift 6 対応。SDK 側の進行管理は SDK 側 issue で扱う
- sora-ios-sdk-samples の対応は 0124 で扱う
- 0122 (legacy `VideoRenderer` API の削除) に伴う quickstart の renderer 移行。0122 が先行した場合は `MediaStream.videoRenderer` の利用の置き換えが必要になるため、実施順を別途決める
- 0148 (quickstart の複数クライアント映像) が先行した場合は受信ストリームの描画部分が変わるため、`onAddStream` の置き換えは 0148 の実装に合わせる

## 参考

- 購読 API の使い方は `skills/sora-ios-sdk/SKILL.md` の「コールバックを Swift 6 で扱う」と「イベントの購読」に記載がある
- SDK 側の Swift 6 関連 issue: 0107 / 0108 / 0109 / 0110 / 0120 / 0122 / 0123
