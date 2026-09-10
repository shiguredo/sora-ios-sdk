# sora-ios-sdk-samples の Swift 6 暫定対応を SDK の本対応へ置き換える

- Created: 2026-08-27
- Completed:
- Branch: feature/update-samples-swift6-native-support
- Polished:

## 目的

sora-ios-sdk の Swift 6 本対応(issue 0107、0108 など)が完了した後、sora-ios-sdk-samples に残っている暫定対応を撤去し、SDK が提供する本対応の API を使う形へ置き換える。

samples は SDK の利用例として公開されており、暫定対応(`@preconcurrency import Sora`、`nonisolated(unsafe)`、`@Sendable` + `Task { @MainActor in }` で束ねる)が長く残ると、利用者に「この暫定対応が必要」と誤った理解をさせ、正しい Swift 6 での SDK 利用イメージを損なう。

## 現状

sora-ios-sdk-samples は Swift 6 言語モード対応時に次の暫定対応を行っている。

- `@preconcurrency import Sora`(8 ファイル)
  - `SamplesApp/SamplesApp/Shared/SoraSDKManager.swift`
  - `SamplesApp/SamplesApp/Features/ScreenCast/ScreenCastEnvironment.swift`
  - `SamplesApp/SamplesApp/Features/ScreenCast/Classes/ScreenCastGameViewController.swift`
  - `SamplesApp/SamplesApp/Features/VideoChat/VideoChatRoomViewController.swift`
  - `SamplesApp/SamplesApp/Features/Simulcast/Classes/SimulcastVideoChatRoomViewController.swift`
  - `SamplesApp/SamplesApp/Features/Spotlight/Classes/SpotlightVideoChatRoomViewController.swift`
  - `SamplesApp/SamplesApp/Features/DataChannel/DataChannelVideoChatRoomViewController.swift`
  - `SamplesApp/SamplesApp/Features/DecoStreaming/Classes/DecoStreamingVideoViewController.swift`
- `@Sendable` 化 + `Task { @MainActor in }` で SDK コールバックを束ねる
  - `Sora.shared.connect` の接続完了コールバック
  - `MediaChannel.handlers.onXXX`(onAddStream、onRemoveStream、onDisconnect、onSwitchVideo、onSwitchAudio、onDataChannelMessage、onReceiveSignalingJSON)
  - `MediaChannelHandlers` 経由の hook(`configuration.mediaChannelHandlers.onReceiveSignalingJSON` 等)
  - `CameraVideoCapturer.flip` の完了コールバック
  - `ScreenCaptureSettings.onRuntimeError` のコールバック
- `nonisolated(unsafe)` による非 Sendable な `MediaChannel` の転送
  - `SoraSDKManager.connect`(接続コールバック)
  - `ScreenCastConnectionManager.connect`(screen / camera の 2 箇所)
  - `RPCRoomViewController.sendRPCAndLog`(MediaChannel / params)
- その他の Swift 6 並行性対応(暫定ではなく本対応と位置づけられるもの)
  - `VideoBitRatePickerTableViewCell.awakeFromNib` の `nonisolated` + `MainActor.assumeIsolated`
  - `ScreenRecorder` の `nonisolated` 化と `@unchecked Sendable`、`ContextThroughBox`
  - `DecoStreamingVideoViewController` の `DecoStreamingVideoCaptureDelegate` 分離(カメラコールバックの非隔離化)

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
2. Sendable event API(0110)や Sendable RPC API(0109)など、境界を越える値を deep Sendable な型で扱う新 API が提供された
3. `onRuntimeError` 等のコールバック型が `@Sendable` 化された

そのうえで、samples 側の対応は次の方針とする。

- `@preconcurrency import Sora` を通常の `import Sora` へ戻す。SDL 側の Sendable 化が完了した型に対しては、SDK の公開 API をそのまま使う
- `@Sendable` + `Task { @MainActor in }` で束ねる対応は、SDK の新 API(0110 の event API 等)が提供された場合はその利用例へ置き換える
- `nonisolated(unsafe)` による `MediaChannel` 転送は、SDK 側で Sendable 化された場合はすべて撤去する。撤去できない場合は、SDK 側の設計に合わせた形へ修正する
- 暫定対応を取り除いた後も、Swift 6 言語モードでビルド・実機確認ができること

samples は SDK の利用例として提供されている。そのため、SDK 側の本対応を反映した利用例を示すことが、この issue の最大の目的である。

## 完了条件

- `@preconcurrency import Sora` が samples からすべて撤去される
- `nonisolated(unsafe)` による非 Sendable な `MediaChannel` 等の転送が撤去される(撤去できない場合はその理由と SDK 側へのフィードバックを記録する)
- SDK が提供する新 API がある場合は、その利用例を各サンプルへ反映する
- samples が Swift 6 言語モードでビルドでき、実機で接続・切断ができること

## スコープ外

- この issue は sora-ios-sdk 本体の Swift 6 対応を含まない
- sora-ios-sdk-quickstart の対応は 0125 で扱う
- SDK 側の Swift 6 対応(0092-0123)それ自体の進行管理は SDK 側 issue で扱う

## 参考

- sora-ios-sdk の issue 0092-0123( Swift 6 本対応のロードマップ)
