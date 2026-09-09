---
name: sora-ios-sdk
description: 時雨堂の WebRTC SFU Sora 向け iOS クライアント SDK (sora-ios-sdk) の利用ガイド。Sora / Configuration / MediaChannel / MediaStream による接続管理、音声・映像の送受信、ソフトミュート / ハードミュート、ステレオ音声出力、Opus パラメーター、カメラ制御、画面キャプチャ、DataChannel メッセージング、RPC、WebRTC 統計情報取得、サイマルキャスト / スポットライト、AudioSession 操作、Swift 6 の並行性要件に関する質問時に使用。
---

# Sora iOS SDK (sora-ios-sdk)

- **バージョン**: `Sora/PackageInfo.swift` の `SDKInfo.version` を参照 (develop は 2026.3.0-canary.0)
- **リポジトリ**: https://github.com/shiguredo/sora-ios-sdk
- **ドキュメント**: https://sora-ios-sdk.shiguredo.jp/
- **API リファレンス**: https://sora-ios-sdk.shiguredo.jp/_static/api/docs/
- **サンプル集**: https://github.com/shiguredo/sora-ios-sdk-samples
- **クイックスタート**: https://github.com/shiguredo/sora-ios-sdk-quickstart

[WebRTC SFU Sora](https://sora.shiguredo.jp) の iOS クライアントアプリケーションを開発するためのライブラリ。Swift 6 言語モードでビルドしている。

## 動作条件

- iOS 14 以降
- アーキテクチャ arm64 (シミュレーターの動作は未保証)
- Xcode 26.2
- WebRTC SFU Sora 2025.2.0 以降

## インストール

Swift Package Manager を利用する。

```swift
.package(url: "https://github.com/shiguredo/sora-ios-sdk.git", from: "2026.2.1")
```

`import Sora` と `import WebRTC` で利用する。

## 基本的な使い方

### 接続の流れ

1. `Configuration` を生成して接続設定を組み立てる
2. `Sora.shared.connect(configuration:webRTCConfiguration:handler:)` で接続する
3. 接続成功時に `MediaChannel` が返る
4. `MediaChannel.handlers` でストリーム追加などのコールバックを登録する
5. `MediaChannel.disconnect(error:)` で切断する

`Sora.shared` はシングルトンだが、接続グループやハンドラーを分けたい場合は `Sora()` でインスタンスを生成できる。

### sendrecv (双方向)

```swift
import Sora
import WebRTC

var config = Configuration(
  url: URL(string: "wss://sora.example.com/signaling")!,
  channelId: "sora",
  role: .sendrecv)

config.mediaChannelHandlers.onAddStream = { stream in
  // 受信ストリーム。VideoView に描画するなど
  if stream.streamId != config.publisherStreamId {
    let videoView = VideoView()
    stream.videoRenderer = videoView
  }
}

config.mediaChannelHandlers.onDisconnect = { event in
  switch event {
  case .ok(let code, let reason):
    print("normal disconnect: \(code) \(reason)")
  case .error(let error):
    print("abnormal disconnect: \(error)")
  }
}

let task = Sora.shared.connect(configuration: config) { mediaChannel, error in
  if let error {
    print("connect failed: \(error)")
    return
  }
  guard let mediaChannel else { return }
  print("connected: \(mediaChannel.connectionId ?? "")")
}
```

この例はトップレベルコードを前提としている。UIViewController などの `@MainActor` クラス内でコールバックを登録する場合、Swift 6 ではクロージャが MainActor 隔離を継承して実行時 trap になるため、「Swift 6 と並行性」の `@Sendable` / `nonisolated(unsafe)` のパターンを使う。

### recvonly (視聴のみ)

```swift
let config = Configuration(
  url: URL(string: "wss://sora.example.com/signaling")!,
  channelId: "sora",
  role: .recvonly)

Sora.shared.connect(configuration: config) { mediaChannel, error in
  // ...
}
```

### sendonly (配信のみ)

```swift
let config = Configuration(
  url: URL(string: "wss://sora.example.com/signaling")!,
  channelId: "sora",
  role: .sendonly)

Sora.shared.connect(configuration: config) { mediaChannel, error in
  // ...
}
```

### 接続のキャンセル

```swift
let task = Sora.shared.connect(configuration: config) { mediaChannel, error in
  // キャンセル時は error に SoraError.connectionCancelled が渡る
}
task.cancel()
```

`ConnectionTask.state` は `.connecting` / `.completed` / `.canceled` のいずれかになる。

## 主な型

### Sora

```swift
// シングルトン
Sora.shared

// SDK の終了処理。アプリ終了時に必ず呼ぶ必要はない
Sora.finish()

// ログレベル (デフォルトは .info)
Sora.logLevel = .debug

// libwebrtc のログレベル
Sora.setWebRTCLogLevel(.info)
```

インスタンス API:

| API | 内容 |
| --- | --- |
| `mediaChannels: [MediaChannel]` | 接続中のメディアチャネル |
| `handlers: SoraHandlers` | 接続・切断・音声ルート変更のコールバック |
| `connect(configuration:webRTCConfiguration:handler:) -> ConnectionTask` | 接続する |
| `usesManualAudio: Bool` | 音声ユニットの手動初期化 |
| `audioEnabled: Bool` | 音声ユニットの使用可否 (`usesManualAudio == true` のとき有効) |
| `configureAudioSession(block:)` | `RTCAudioSession` をロックして設定する |
| `setAudioMode(_:options:) -> Result<Void, Error>` | 音声モード・カテゴリ・出力先を変更する |

### SoraHandlers

| プロパティ | 内容 |
| --- | --- |
| `onConnect: ((MediaChannel?, Error?) -> Void)?` | 接続成功・失敗 |
| `onDisconnect: ((MediaChannel, Error?) -> Void)?` | 接続解除 |
| `onAddMediaChannel: ((MediaChannel) -> Void)?` | メディアチャネル追加 |
| `onRemoveMediaChannel: ((MediaChannel) -> Void)?` | メディアチャネル除去 |
| `onChangeAudioRoute: ((RTCAudioSession, AVAudioSession.RouteChangeReason, AVAudioSessionRouteDescription) -> Void)?` | 音声入出力ルート変更 |

### Configuration

`Configuration` は `struct` であり、接続ごとに値を設定する。

接続:

| プロパティ | 型 | 内容 |
| --- | --- | --- |
| `urlCandidates` | `[URL]` | シグナリング URL の候補 |
| `channelId` | `String` | チャネル ID |
| `clientId` / `bundleId` | `String?` | クライアント ID / バンドル ID |
| `role` | `Role` | `.sendonly` / `.recvonly` / `.sendrecv` |
| `connectionTimeout` | `Int` | 接続タイムアウト秒 (デフォルト 30) |
| `webRTCConfiguration` | `WebRTCConfiguration` | ICE サーバー・ICE ポリシー・劣化設定 |

音声:

| プロパティ | 型 | 内容 |
| --- | --- | --- |
| `audioEnabled` | `Bool` | 音声の可否 (デフォルト `true`) |
| `audioCodec` | `AudioCodec` | `.default` (Opus) / `.opus` / `.pcmu` |
| `audioBitRate` | `Int?` | 音声ビットレート |
| `audioOpusParams` | `Encodable?` | `audioCodec == .opus` のときだけ `audio.opus_params` として送信 |
| `audioStereoOutputEnabled` | `Bool` | 受信音声をステレオ再生 (デフォルト `false`) |
| `initialMicrophoneEnabled` | `Bool` | 接続時のマイク有効化 (デフォルト `true`) |
| `bypassVoiceProcessing` | `Bool` | 音声入力処理をバイパス (デフォルト `false`) |
| `audioStreamingLanguageCode` | `String?` | 音声ストリーミングの言語コード |

映像:

| プロパティ | 型 | 内容 |
| --- | --- | --- |
| `videoEnabled` | `Bool` | 映像の可否 (デフォルト `true`) |
| `videoCodec` | `VideoCodec` | `.default` (VP9) / `.vp8` / `.vp9` / `.h264` / `.h265` / `.av1` |
| `videoBitRate` | `Int?` | 映像ビットレート |
| `cameraSettings` | `CameraSettings` | 解像度・フレームレート・カメラ位置・起動有無 |
| `initialCameraEnabled` | `Bool` | 接続時のカメラ起動 (デフォルト `true`) |
| `videoVp9Params` / `videoAv1Params` / `videoH264Params` / `videoH265Params` | `Encodable?` | コーデック固有パラメーター。`videoCodec` と一致するときだけ送信される |

サイマルキャスト / スポットライト:

| プロパティ | 型 | 内容 |
| --- | --- | --- |
| `simulcastEnabled` | `Bool` | サイマルキャストの可否 |
| `simulcastRequestRid` | `SimulcastRequestRid` | 受信する rid (`.unspecified` / `.none` / `.r0` / `.r1` / `.r2`) |
| `isSpotlightEnabled` | `Bool` | スポットライトの可否 |
| `spotlightNumber` | `Int?` | スポットライトの対象人数 |
| `spotlightFocusRid` / `spotlightUnfocusRid` | `SpotlightRid` | フォーカス時 / 非フォーカス時の rid |

DataChannel / シグナリング:

| プロパティ | 型 | 内容 |
| --- | --- | --- |
| `dataChannelSignaling` | `Bool?` | DataChannel 経由のシグナリング |
| `dataChannels` | `Any?` | メッセージング用 DataChannel の定義 (`JSONSerialization` 可能な形式) |
| `ignoreDisconnectWebSocket` | `Bool?` | DataChannel シグナリング利用時に WebSocket 切断を無視する |
| `signalingConnectMetadata` | `Encodable?` | `type: connect` に含めるメタデータ |
| `signalingConnectNotifyMetadata` | `Encodable?` | `type: connect` に含める通知用メタデータ |

ネットワーク / セキュリティ:

| プロパティ | 型 | 内容 |
| --- | --- | --- |
| `proxy` | `Proxy?` | HTTP プロキシ |
| `caCertificate` | `String?` | サーバー証明書検証用の CA 証明書 (PEM) |
| `insecure` | `Bool` | サーバー証明書検証をスキップする (開発・検証目的のみ) |
| `forwardingFilters` | `[ForwardingFilter]?` | リスト形式の転送フィルター |

イベントハンドラ:

| プロパティ | 型 |
| --- | --- |
| `mediaChannelHandlers` | `MediaChannelHandlers` |
| `webSocketChannelHandlers` | `WebSocketChannelHandlers` |

パブリッシャー (通常は変更不要):

| プロパティ | 内容 |
| --- | --- |
| `publisherStreamId` | 送信ストリーム ID |
| `publisherVideoTrackId` / `publisherAudioTrackId` | 送信トラック ID |

### MediaChannel

接続情報:

| プロパティ | 内容 |
| --- | --- |
| `configuration` | 接続に使った `Configuration` |
| `state` | `ConnectionState` (`.connecting` / `.connected` / `.disconnecting` / `.disconnected`) |
| `isAvailable` | `state == .connected` |
| `clientId` / `bundleId` / `connectionId` | 接続後に設定される ID |
| `contactUrl` / `connectedUrl` | 最初に `type: connect` を送った URL / 接続中の URL |
| `connectionStartTime` / `connectionTime` | 接続開始時刻 / 接続時間 (秒) |
| `connectionCount` / `publisherCount` / `subscriberCount` | 同チャネルの接続人数 |
| `streams` / `mainStream` / `senderStream` / `receiverStreams` | ストリーム |
| `native` | 内部の `RTCPeerConnection` |
| `handlers` | `MediaChannelHandlers` |

操作:

```swift
// 切断する。error に nil を渡すと正常切断
mediaChannel.disconnect(error: nil)

// WebRTC 統計情報を取得する
mediaChannel.getStats { result in
  switch result {
  case .success(let statistics):
    print(statistics.jsonObject)
  case .failure(let error):
    print(error)
  }
}

// DataChannel でメッセージを送信する (label は # 始まり)
let error: Error? = mediaChannel.sendMessage(label: "#spam", data: Data("hello".utf8))

// 音声ハードミュート (マイクインジケーターを消灯する)
let error: Error? = mediaChannel.setAudioHardMute(true)

// 音声ソフトミュート (デジタルサイレンスを送る)
let error: Error? = mediaChannel.setAudioSoftMute(true)

// 映像ソフトミュート (黒塗りフレームを送る)
let error: Error? = mediaChannel.setVideoSoftMute(true)

// 映像ハードミュート (カメラを停止する)
try await mediaChannel.setVideoHardMute(true)

// 画面キャプチャの開始 / 停止
try await mediaChannel.startScreenCapture(settings: ScreenCaptureSettings(targetFPS: 15))
await mediaChannel.stopScreenCapture()
let active: Bool = mediaChannel.isScreenCaptureActive()

// RPC
let response = try await mediaChannel.rpc(
  method: RequestSimulcastRid.self,
  params: RequestSimulcastRidParams(rid: .r0)
)
```

### MediaChannelHandlers

| プロパティ | 内容 |
| --- | --- |
| `onConnect: ((Error?) -> Void)?` | 接続成功 |
| `onDisconnect: ((SoraCloseEvent) -> Void)?` | 接続解除 |
| `onAddStream: ((MediaStream) -> Void)?` | ストリーム追加 |
| `onRemoveStream: ((MediaStream) -> Void)?` | ストリーム除去 |
| `onReceiveSignalingJSON: ((String) -> Void)?` | シグナリング受信 (JSON 文字列) |
| `onDataChannel: ((MediaChannel) -> Void)?` | メッセージング用 DataChannel がすべて OPEN |
| `onDataChannelOpened: ((MediaChannel, String) -> Void)?` | ラベルごとの DataChannel OPEN |
| `onDataChannelMessage: ((MediaChannel, String, Data) -> Void)?` | DataChannel メッセージ受信 |

### MediaStream

`MediaStream` はプロトコルであり、SDK 内部の実装が渡される。

| プロパティ / メソッド | 内容 |
| --- | --- |
| `streamId` / `creationTime` / `mediaChannel` | ストリーム情報 |
| `videoEnabled` / `audioEnabled` | 送受信の可否 (ソフトミュート相当。マイクは止まらない) |
| `hasVideoTrack` / `hasAudioTrack` | トラックの有無 |
| `remoteAudioVolume: Double?` | 受信音量 (0 から 10) |
| `videoFilter` / `videoRenderer` | 映像フィルター / 描画先 |
| `addAudioTrackSink(_:)` / `removeAudioTrackSink(_:)` | 受信 PCM の取得 |
| `send(videoFrame:)` | 映像フレームを送信する |
| `handlers` | `MediaStreamHandlers` (`onSwitchVideo` / `onSwitchAudio`) |
| `terminate()` | 終了処理 |

## 音声

### ステレオ音声出力

`Configuration.audioStereoOutputEnabled` を `true` にすると、受信した Opus 音声をステレオで再生できる。既定値は `false` で、従来のモノラル出力を維持する。

```swift
var configuration = Configuration(
  urlCandidates: [url],
  channelId: channelId,
  role: .recvonly)
configuration.audioStereoOutputEnabled = true
```

役割ごとの音声入力:

- `recvonly` ではマイク入力を初期化しない。マイク権限も必要ない
- `sendonly` と `sendrecv` ではマイク入力を初期化する。`initialMicrophoneEnabled` と `MediaChannel.setAudioHardMute(_:)` で制御できる

制約:

- Voice Processing I/O の代わりに RemoteIO を利用するため、AEC と AGC は利用できない
- `bypassVoiceProcessing` の指定は無視される
- `audioEnabled == false` または `audioCodec == .pcmu` とは併用できない。`.default` でも Answer の受信方向に Opus がなければ接続に失敗する
- SDK が管理する音声接続全体でステレオ接続は 1 つだけ。他の音声接続とは同時に利用できない
- Bluetooth HFP はモノラル。A2DP はステレオ出力を利用できるが、SDK は route を自動で切り替えない
- 接続後に `setAudioMode(.voiceChat(...))` を呼ぶとモノラルへ切り替わる場合がある

`recvonly` のマイク権限不要化と、ステレオ送信側の入力制御には、RemoteIO の手動入力初期化とハードミュートに対応した WebRTC-Build が必要となる。`Package.swift` は m150.7871.3.5 を参照している。

### ミュート

- ソフトミュート: `MediaChannel.setAudioSoftMute(_:)` / `setVideoSoftMute(_:)`。トラックを無効にしてデジタルサイレンス / 黒塗りフレームを送る
- ハードミュート: `MediaChannel.setAudioHardMute(_:)` / `setVideoHardMute(_:)`。マイクやカメラを停止してプライバシーインジケーターを消す
- 接続時の状態: `initialMicrophoneEnabled` / `initialCameraEnabled` で指定する

### AudioSession

```swift
// AVAudioSession をロックして設定する
Sora.shared.configureAudioSession {
  // RTCAudioSession のプロパティを操作する
}

// 音声モードを変更する (接続完了後に呼ぶ)
let result = Sora.shared.setAudioMode(.videoChat)
```

`AudioMode` は `.default(category:output:)` / `.videoChat` / `.voiceChat(output:)`、`AudioOutput` は `.default` / `.speaker`。

### 受信 PCM の取得

`RTCAudioTrackSink` を実装し、`MediaStream.addAudioTrackSink(_:)` で関連付ける。`onData` は libwebrtc の音声処理スレッドで 10 ms ごとに呼ばれるため、時間のかかる処理をしてはいけない。

## 映像

### カメラ設定

`CameraSettings` で解像度・フレームレート・カメラ位置・起動有無を指定する。

```swift
config.cameraSettings = CameraSettings(
  resolution: .hd720p,
  frameRate: 30,
  position: .front,
  isEnabled: true)
```

解像度は `.qvga240p` (320x240) / `.vga480p` (640x480) / `.qhd540p` (960x540) / `.hd720p` (1280x720) / `.hd1080p` (1920x1080) / `.uhd2160p` (3840x2160) / `.uhd3024p` (4032x3024)。

### カメラ操作

```swift
// 利用可能なデバイス
let devices = CameraVideoCapturer.devices
let front = CameraVideoCapturer.front
let back = CameraVideoCapturer.back
let current = CameraVideoCapturer.current

// 解像度に近いフォーマットを取得する
let device = CameraVideoCapturer.device(for: .back)!
let format = CameraVideoCapturer.format(width: 1280, height: 720, for: device, frameRate: 30)!

// 起動 / 停止 / 再起動 / 設定変更
current?.start(format: format, frameRate: 30) { error in /* ... */ }
current?.stop { error in /* ... */ }
current?.restart { error in /* ... */ }
current?.change(format: format, frameRate: 60) { error in /* ... */ }

// フロント / リアを切り替える
CameraVideoCapturer.flip(current!) { error in /* ... */ }
```

`CameraVideoCapturer.handlers.onCapture` で生成フレームを加工できる。

### 画面キャプチャ

ReplayKit を利用して端末画面を配信する。

```swift
try await mediaChannel.startScreenCapture(
  settings: ScreenCaptureSettings(
    targetFPS: 15,
    videoSampleBufferTransformer: { sampleBuffer in sampleBuffer },
    onRuntimeError: { error in print(error) }))
await mediaChannel.stopScreenCapture()
```

同一送信ストリームでカメラと画面キャプチャは同時に使えない。`initialCameraEnabled = false` にするか、`setVideoHardMute(true)` でカメラを止めてから開始する。

### 描画

`VideoView` (`UIView`) を `MediaStream.videoRenderer` に設定する。`VideoRenderer` プロトコルを実装した独自ビューも利用できる。`VideoView.connectionMode` で切断時の挙動 (`.auto` / `.autoClear` / `.manual`) を指定する。

`VideoFilter` プロトコルを実装して `MediaStream.videoFilter` に設定すると、送信する映像フレームを加工できる。

## DataChannel メッセージング

`Configuration.dataChannels` に `JSONSerialization` 可能な形式で定義する。label は `#` 始まりにする。

```swift
config.dataChannelSignaling = true
config.dataChannels = [[
  "label": "#spam",
  "direction": "sendrecv",
  "compress": true,
]]
```

送信は `MediaChannel.sendMessage(label:data:)`、受信は `MediaChannelHandlers.onDataChannelMessage` で行う。対象ラベルが OPEN になるまで送信できないため、`onDataChannelOpened` を待つ。

## RPC

`MediaChannel.rpc(method:params:isNotificationRequest:timeout:)` は async / await で呼ぶ。利用可能なメソッドは `SignalingOffer.rpcMethods` で確認できる。

| メソッド型 | 内容 |
| --- | --- |
| `RequestSimulcastRid` | 受信するサイマルキャスト rid を変更する |
| `RequestSpotlightRid` | スポットライトの rid を指定する |
| `ResetSpotlightRid` | スポットライトの rid をリセットする |
| `PutSignalingNotifyMetadata` | シグナリング通知メタデータを設定する |
| `PutSignalingNotifyMetadataItem` | メタデータの特定キーに値を設定する |

## 統計

```swift
mediaChannel.getStats { result in
  switch result {
  case .success(let statistics):
    for entry in statistics.entries {
      print(entry.type, entry.id, entry.values)
    }
  case .failure(let error):
    print(error)
  }
}
```

## 切断イベント

`MediaChannelHandlers.onDisconnect` で `SoraCloseEvent` を受け取る。

```swift
config.mediaChannelHandlers.onDisconnect = { event in
  switch event {
  case .ok(let code, let reason):
    // 正常切断 (WebSocket の 1000 など)
  case .error(let error):
    // 異常切断 (SoraError.webSocketError など)
  }
}
```

再接続は SDK では自動で行わない。異常切断を契機にアプリ側で再接続する。

## Swift 6 と並行性

SDK 本体は Swift 6 言語モードでビルド・ CI 検証している。ただし `Package.swift` の `swift-tools-version` は 5.3 のため、SwiftPM で取り込んだ場合にパッケージ側へ適用される言語モードは Swift 5 になる。CI の `SWIFT_VERSION=6` は通常の SwiftPM consumer へ伝播しない。利用側のアプリを Swift 6 言語モードでビルドする場合は、次の点に注意する。

### Sendable 準拠

SDK が公開型に `Sendable` 準拠を追加しているため、利用側で独自に `Sendable` 準拠を追加していた場合は削除が必要になる。

- `Sendable`: `Role` / `AudioCodec` / `VideoCodec` / `Rid` / `SimulcastRid` / `SimulcastRequestRid` / `SpotlightRid` / `ICETransportPolicy` / `SDPSemantics` / `AspectRatio` / `WebSocketStatusCode` / `DeviceInfo` / `Proxy` / `CameraSettings.Resolution`
- `@unchecked Sendable`: `Sora` / `Logger` / `CameraVideoCapturer`
- `Sendable` ではない: `Configuration` / `MediaChannel` / `MediaStream` / `MediaChannelHandlers` / `SoraHandlers` / `Statistics` / `VideoView` など

`MediaChannel` や `MediaStream` を `Task` や別 actor へそのまま渡すことはできない。`@MainActor` の型や `Task { @MainActor in ... }` に閉じ込めるなど、利用側で隔離する。

### コールバックのスレッド

コールバックの呼び出し元スレッドは保証されない。UI 更新や共有状態の変更は main queue / main actor へ束ねる。

- `SoraHandlers` / `MediaChannelHandlers` の各コールバック (`onConnect` / `onDisconnect` / `onAddStream` / `onDataChannel` など)
- `MediaStreamHandlers` の `onSwitchVideo` / `onSwitchAudio`
- `RTCAudioTrackSink.onData` は libwebrtc の音声処理スレッド (10 ms ごと)
- `CameraVideoCapturer.handlers.onCapture` はカメラキャプチャスレッド
- `VideoRenderer` の `onChange` / `render` は SDK が main thread へ配送する

### コールバックを Swift 6 で扱う

`@MainActor` のクラス (UIViewController など) の中でコールバッククロージャを書くと、クロージャが MainActor 隔離を継承する。SDK はシグナリングスレッドなどからコールバックを呼ぶため、そのままでは Swift 6 の実行時隔離チェックで `EXC_BREAKPOINT` になる。クロージャに `@Sendable` を付けるか、`nonisolated` な関数へ処理を分離して隔離を外す。

非 Sendable な `MediaChannel` を `Task` へ渡す場合は `nonisolated(unsafe) let` を使い、`Task { @MainActor in ... }` で main actor へ移す。

```swift
_ = Sora.shared.connect(configuration: config) { @Sendable [weak self] mediaChannel, error in
  // MediaChannel は非 Sendable のため nonisolated(unsafe) で Task へ渡す
  nonisolated(unsafe) let channel = mediaChannel
  Task { @MainActor in
    guard let self else { return }
    if let channel {
      self.mediaChannel = channel
    }
  }
}
```

`@preconcurrency import Sora` は Sendable 関連の診断を抑止する暫定対応であり、SDK が Sendable な event / RPC / statistics API を提供するまでの間、サンプル集とクイックスタートでも使われている。将来 SDK 側の対応が進んだら不要になる。

`MediaChannelHandlers` のコールバックも同じ考え方で扱う。

```swift
// UIViewController などの @MainActor クラス内
config.mediaChannelHandlers.onAddStream = { @Sendable [weak self] stream in
  // MediaStream は非 Sendable のため nonisolated(unsafe) で Task へ渡す
  nonisolated(unsafe) let stream = stream
  Task { @MainActor in
    guard let self else { return }
    self.attach(stream: stream)
  }
}

config.mediaChannelHandlers.onDisconnect = { @Sendable [weak self] event in
  Task { @MainActor in
    guard let self else { return }
    self.handleDisconnect(event)
  }
}
```

### 非同期 API

`async` / `await` に対応するのは `MediaChannel.rpc` / `setVideoHardMute` / `startScreenCapture` / `stopScreenCapture`。それ以外のミュートや `getStats` / `sendMessage` は同期 API で、結果を戻り値やコールバックで受け取る。

### スレッド安全でない共有状態

次の静的プロパティは `nonisolated(unsafe)` であり、コンパイラによるスレッド安全の検証対象外となる。同時に読み書きしない前提で利用する。

- `DeviceInfo.current`
- `CameraVideoCapturer.current` / `CameraVideoCapturer.handlers`
- `Logger.shared` / `Sora.logLevel`

カメラ操作 (`start` / `stop` / `restart` / `change` / `flip`) は SDK 内部で直列化されるが、`CameraVideoCapturer.current` を利用側から書き換えないこと。

### 現状の制約

- `Package.swift` の `swift-tools-version` は 5.3 のままで、manifest からの Swift 6 言語モード指定は未対応
- Sendable な event / RPC / statistics API はまだ提供されていない。`MediaChannel` / `MediaStream` を境界で扱うには `nonisolated(unsafe)` や actor 隔離が必要
- サンプル集とクイックスタートは Swift 6 言語モードだが、`@preconcurrency import Sora` と `nonisolated(unsafe)` の暫定対応を含む。Swift 6 の模範例ではなく、暫定対応を含む参考実装として扱う

## 非推奨 API

| 非推奨 | 代替 |
| --- | --- |
| `Configuration.multistreamEnabled` | 指定しない |
| `Configuration.simulcastRid` | `Configuration.simulcastRequestRid` |
| `Configuration.spotlightEnabled` (enum) | `Configuration.isSpotlightEnabled` (Bool) |
| `MediaChannelHandlers.onDisconnectLegacy` | `MediaChannelHandlers.onDisconnect` |
| `MediaChannelHandlers.onReceiveSignaling` | `MediaChannelHandlers.onReceiveSignalingJSON` |
| `ICEServerInfo.tlsSecurityPolicy` / `TLSSecurityPolicy` | `Configuration.insecure` |
| `MediaChannelConfiguration` | 廃止 (`Configuration` を利用する) |

## クイックリファレンス

| やりたいこと | API |
| --- | --- |
| 接続 | `Sora.shared.connect(configuration:webRTCConfiguration:handler:)` |
| 切断 | `MediaChannel.disconnect(error:)` |
| 接続キャンセル | `ConnectionTask.cancel()` |
| 受信ストリームの描画 | `stream.videoRenderer = VideoView()` |
| 音声ソフトミュート | `MediaChannel.setAudioSoftMute(_:)` |
| 音声ハードミュート | `MediaChannel.setAudioHardMute(_:)` |
| 映像ソフトミュート | `MediaChannel.setVideoSoftMute(_:)` |
| 映像ハードミュート | `try await MediaChannel.setVideoHardMute(_:)` |
| ステレオ音声出力 | `Configuration.audioStereoOutputEnabled = true` |
| Opus パラメーター | `Configuration.audioOpusParams` |
| カメラ切り替え | `CameraVideoCapturer.flip(_:completionHandler:)` |
| 画面キャプチャ | `try await MediaChannel.startScreenCapture(settings:)` |
| メッセージ送信 | `MediaChannel.sendMessage(label:data:)` |
| メッセージ受信 | `MediaChannelHandlers.onDataChannelMessage` |
| RPC | `try await MediaChannel.rpc(method:params:)` |
| 統計取得 | `MediaChannel.getStats(handler:)` |
| 受信音量 | `MediaStream.remoteAudioVolume` |
| 受信 PCM | `MediaStream.addAudioTrackSink(_:)` |
