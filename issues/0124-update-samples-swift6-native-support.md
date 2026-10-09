# sora-ios-sdk-samples の Swift 6 暫定対応を SDK の本対応へ置き換える

- Created: 2026-08-27
- Completed:
- Branch: feature/update-samples-swift6-native-support
- Polished: 2026-10-08

## 目的

sora-ios-sdk の Swift 6 本対応 (0110 の Sendable event API と 0109 の Sendable RPC API など) が sora-ios-sdk 2026.4.0-canary.2 に取り込まれたため、sora-ios-sdk-samples に残っている暫定対応を撤去し、SDK が提供する本対応の API を使う形へ置き換える。

samples は SDK の利用例として公開されており、暫定対応 (`@preconcurrency import Sora`、`nonisolated(unsafe)`) が長く残ると、利用者に「この暫定対応が必要」と誤った理解をさせ、正しい Swift 6 での SDK 利用イメージを損なう。

## 前提

- 変更するのは sora-ios-sdk-samples リポジトリで、sora-ios-sdk 本体のコードは変更しない。`Branch:` は sora-ios-sdk-samples に切るブランチ名である
- sora-ios-sdk 2026.4.0-canary.2 には、0110 が追加した `Sora.subscribeEvents(bufferingPolicy:)` と `MediaChannel.subscribeEvents(bufferingPolicy:)` (完了 2026-10-07)、0109 が追加した `MediaChannel.sendableRPC(method:params:isNotificationRequest:timeout:)` (完了 2026-09-30) が取り込まれている
- samples は SDK を `SamplesApp/SamplesApp.xcodeproj/project.pbxproj` の `exactVersion` で 2026.2.1 に固定しており、README も 2026.2.1 と表記している。2026.2.1 には 0110 と 0109 の API が無いため、先に 2026.4.0-canary.2 へ上げる。samples は `Package.resolved` を git 管理していない
- 2026.4.0-canary.2 の `Package.swift` は `swift-tools-version:6.3` のため、SwiftPM で取り込むには Xcode 26.6 以上 (SwiftPM 6.3 以上) が必要になる。README のシステム条件と `.github/workflows/build.yml` の Xcode 条件も更新する
- `MediaChannel` / `MediaStream` は `Sendable` にはならない (`skills/sora-ios-sdk/SKILL.md` と SDK のドキュメントコメントが明記している)。SDK は `Sendable` 化ではなく、値として確定したイベントを配送する購読 API で境界を越える設計を採っている
- `ScreenCaptureSettings.onRuntimeError` のコールバック型は `((Error) -> Void)`、`CameraVideoCapturer.flip` の `completionHandler` は `@escaping ((Error?) -> Void)` のままで、`@Sendable` にはならず購読 API にも置き換えられない
- 0160 (Xcode プロジェクト設定ファイル形式の更新) が先行した場合は `project.pbxproj` ではなく `project.xcproj` を変更し、Xcode の条件は 0160 の値を維持する

## 変更対象

sora-ios-sdk-samples の次のファイル。

`@preconcurrency import Sora` を撤去し、legacy の handler を購読 API へ置き換える。対象は「現状」に挙げた 8 ファイル。

- `SamplesApp/SamplesApp/Shared/SoraSDKManager.swift`
- `SamplesApp/SamplesApp/Features/ScreenCast/ScreenCastEnvironment.swift`
- `SamplesApp/SamplesApp/Features/ScreenCast/Classes/ScreenCastGameViewController.swift`
- `SamplesApp/SamplesApp/Features/VideoChat/VideoChatRoomViewController.swift`
- `SamplesApp/SamplesApp/Features/Simulcast/Classes/SimulcastVideoChatRoomViewController.swift`
- `SamplesApp/SamplesApp/Features/Spotlight/Classes/SpotlightVideoChatRoomViewController.swift`
- `SamplesApp/SamplesApp/Features/DataChannel/DataChannelVideoChatRoomViewController.swift`
- `SamplesApp/SamplesApp/Features/DecoStreaming/Classes/DecoStreamingVideoViewController.swift`

`nonisolated(unsafe)` を撤去する。対象は上記 8 ファイルのうち `SoraSDKManager.swift`、`ScreenCastEnvironment.swift`、`DecoStreamingVideoViewController.swift` の 3 ファイルと、次の 1 ファイル。RPC は `sendableRPC` へ移行する。

- `SamplesApp/SamplesApp/Features/RPC/RPCRoomViewController.swift`

legacy の hook を購読 API へ置き換える。

- `SamplesApp/SamplesApp/Features/RPC/RPCConfigViewController.swift`

SDK のバージョンとシステム条件を更新する。

- `SamplesApp/SamplesApp.xcodeproj/project.pbxproj` (SDK 依存の `exactVersion`。0160 の実施後は `project.xcproj`)
- `README.md` (システム条件の Xcode と Swift、SDK のバージョン表記)
- `.github/workflows/build.yml` (`XCODE` と `XCODE_SDK`)
- `CHANGES.md` (SDK バージョン更新と Swift 6 対応)

## 現状

sora-ios-sdk-samples は Swift 6 言語モード対応時に次の暫定対応を行っている。

- `@preconcurrency import Sora` (8 ファイル)
  - `SamplesApp/SamplesApp/Shared/SoraSDKManager.swift`
  - `SamplesApp/SamplesApp/Features/ScreenCast/ScreenCastEnvironment.swift`
  - `SamplesApp/SamplesApp/Features/ScreenCast/Classes/ScreenCastGameViewController.swift`
  - `SamplesApp/SamplesApp/Features/VideoChat/VideoChatRoomViewController.swift`
  - `SamplesApp/SamplesApp/Features/Simulcast/Classes/SimulcastVideoChatRoomViewController.swift`
  - `SamplesApp/SamplesApp/Features/Spotlight/Classes/SpotlightVideoChatRoomViewController.swift`
  - `SamplesApp/SamplesApp/Features/DataChannel/DataChannelVideoChatRoomViewController.swift`
  - `SamplesApp/SamplesApp/Features/DecoStreaming/Classes/DecoStreamingVideoViewController.swift`
- `nonisolated(unsafe)` による非 Sendable な `MediaChannel` / `MediaStream` / params の転送 (4 ファイル、7 箇所)
  - `SoraSDKManager.connect` (接続コールバック、1 箇所)
  - `ScreenCastConnectionManager.connect` (screen と camera の 2 箇所)
  - `RPCRoomViewController.sendRPCAndLog` (`MediaChannel` と params の 2 箇所)
  - `DecoStreamingVideoViewController` (送信側の `MediaStream` の転送、2 箇所)
- SDK のコールバックを `@Sendable` クロージャと `Task { @MainActor in }` で束ねる対応
  - `Sora.shared.connect(configuration:handler:)` の `handler`
  - `MediaChannel.handlers` (onAddStream、onRemoveStream、onDisconnect、onDataChannelMessage、onReceiveSignalingJSON)
  - `MediaStream.handlers` (onSwitchVideo、onSwitchAudio)
  - `configuration.mediaChannelHandlers.onReceiveSignalingJSON` (`RPCConfigViewController` の 1 箇所)
  - `CameraVideoCapturer.flip` の完了コールバック
  - `ScreenCaptureSettings.onRuntimeError` のコールバック
  - `@Sendable` と `Task { @MainActor in }` は SDK のコールバックを MainActor から安全に扱うために必要な書き方であり (`skills/sora-ios-sdk/SKILL.md` の「コールバックを Swift 6 で扱う」)、`flip` と `onRuntimeError` は置き換え先が無いため残す
- その他の Swift 6 並行性対応 (暫定ではなく本対応と位置づける)
  - `VideoBitRatePickerTableViewCell.awakeFromNib` の `nonisolated` と `MainActor.assumeIsolated`
  - `ScreenRecorder` の `nonisolated` 化と `@unchecked Sendable`、`ContextThroughBox`
  - `DecoStreamingVideoViewController` の `DecoStreamingVideoCaptureDelegate` 分離 (カメラコールバックの非隔離化)

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

SDK 側の前提は充足している。0110 の購読 API と 0109 の Sendable RPC API が 2026.4.0-canary.2 に取り込まれているため、これらを使って暫定対応を置き換える。`MediaChannel` / `MediaStream` の `Sendable` 化は待たない。

- SDK 依存を 2026.4.0-canary.2 へ上げ、README のシステム条件と CI の Xcode を Xcode 26.6 以上 (SwiftPM 6.3 以上) に合わせる
- `@preconcurrency import Sora` を撤去し、通常の `import Sora` へ戻す
- SDK のコールバックを購読 API へ置き換える
  - 接続結果は `Sora.subscribeEvents(bufferingPolicy:)` の `.connected` / `.connectFailed` で受ける。購読は接続前に開始する
  - 受信ストリームは `MediaChannel.subscribeEvents(bufferingPolicy:)` の `.streamAdded` / `.streamRemoved` と `MediaChannel.streams` で `streamId` から解決する
  - 切断は `.disconnected`、シグナリングは `.signalingReceivedJSON`、DataChannel は `.dataChannelMessage`、映像と音声の有効フラグは `.videoEnabledChanged` / `.audioEnabledChanged` を使う
  - `MediaChannel` の実体は `Sora.mediaChannels` から取得する
- RPC は `MediaChannel.sendableRPC(method:params:isNotificationRequest:timeout:)` へ移行する
- 購読 API に置き換えられない箇所 (`CameraVideoCapturer.flip` の完了コールバック、`ScreenCaptureSettings.onRuntimeError`、`.streamAdded` で `streamId` から解決できない stream) は、SDK のドキュメントコメントに従い、`@Sendable` を付けたクロージャと `nonisolated(unsafe) let` + `Task { @MainActor in ... }` で隔離を外す
- `nonisolated(unsafe)` は、購読 API と `sendableRPC` への置き換えで不要になった箇所を撤去する。残す箇所は理由をコメントに書く
- その他の Swift 6 並行性対応 (`ScreenRecorder` の `nonisolated` 化など) は本対応として維持する

samples は SDK の利用例として提供されている。SDK 側の本対応を反映した利用例を示すことが、この issue の最大の目的である。

## 完了条件

- samples が sora-ios-sdk 2026.4.0-canary.2 を利用している (`project.pbxproj` の `exactVersion` と README のバージョン表記が 2026.4.0-canary.2)
- `@preconcurrency import Sora` が samples からすべて撤去される。撤去できない場合は、どの API が原因かを特定して記録する
- `nonisolated(unsafe)` のうち、購読 API と `sendableRPC` への置き換えで不要になった箇所が撤去され、残した箇所は理由がコメントに書かれている
- legacy の handler のうち購読 API に置き換えられるものが、その利用例へ置き換わっている
- samples が Swift 6 言語モードでビルドでき、実機で接続と切断ができる
- README のシステム条件と `.github/workflows/build.yml` の Xcode が Xcode 26.6 以上 (SwiftPM 6.3 以上) に更新される
- CHANGES.md に SDK バージョン更新と Swift 6 対応が記載される

## スコープ外

- sora-ios-sdk 本体の Swift 6 対応。SDK 側の進行管理は SDK 側 issue で扱う
- sora-ios-sdk-quickstart の対応は 0125 で扱う
- 0122 (legacy `VideoRenderer` API の削除) に伴う renderer 移行。0122 が先行した場合は `MediaStream.videoRenderer` の利用の置き換えが必要になるため、実施順を別途決める
- 0027 (MainActor UI renderer API) の完了を待つ renderer 移行
- 0167 (samples をビデオチャットアプリ 1 種類へ集約する) が先行して実施された場合は、削除されるサンプル (Simulcast / Spotlight / DataChannel / ScreenCast / DecoStreaming / RPC) の Swift 6 対応は本 issue の対象外とし、残るビデオチャットサンプルと共通部品のみを対象とする

## 参考

- 購読 API と `@Sendable` の扱いは `skills/sora-ios-sdk/SKILL.md` の「コールバックを Swift 6 で扱う」「イベントの購読」「現状の制約」に記載がある
- SDK 側の Swift 6 関連 issue: 0107 / 0108 / 0109 / 0110 / 0120 / 0122 / 0123
