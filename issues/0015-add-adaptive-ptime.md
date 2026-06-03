# adaptivePtime に対応する

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-adaptive-ptime

## 目的

音声送信における adaptivePtime（適応的パケット化時間）を設定できるようにする。libwebrtc（iOS）の `RTCRtpEncodingParameters` には `adaptiveAudioPacketTime` プロパティが用意されており、これを有効化することで音声送信のフレーム長を動的に変更できる。

## 前提

本対応の前提として、利用しているバージョンの libwebrtc で `RTCRtpEncodingParameters.adaptiveAudioPacketTime` が実際に有効に機能することを事前に確認する。確認できない場合は pending とする。

## 優先度根拠

Medium とする。libwebrtc 側の API 対応が確認済みであり、音声品質や帯域効率に関わる機能追加であるため Medium が妥当である。緊急のバグ修正ではないため High ではない。

## 現状

iOS SDK には adaptivePtime を制御する API が存在しない。

`RTCRtpEncodingParameters` を生成する `rtpEncodingParameters` では `rid` / `maxBitrate` / `maxFramerate` / `scaleResolutionDownBy` / `scaleResolutionDownTo` / `scalabilityMode` のみを設定しており、`adaptiveAudioPacketTime` は設定していない。またこの `Encoding` 構造体は映像エンコーディング向けに使われている（`Sora/Signaling.swift:412`）。

音声送信トランシーバーは以下で構成されているが、`sender.parameters` の `encodings` に対する adaptivePtime の設定は行っていない。映像向けには `degradationPreference` を `sender.parameters` 経由で設定するパターンが確立している。

```swift
audioTransceiver.sender.streamIds = [nativeStream.streamId]

if let audioTrack = nativeStream.audioTracks.first {
  audioTransceiver.sender.track = audioTrack
}
```

`Sora/PeerChannel.swift:468`

```swift
if let degradationPreference = configuration.webRTCConfiguration
  .degradationPreference
{
  let parameters = videoTransceiver.sender.parameters
  parameters.degradationPreference = NSNumber(
    value: degradationPreference.nativeValue.rawValue)
  videoTransceiver.sender.parameters = parameters
}
```

`Sora/PeerChannel.swift:501`

## 設計方針

`Configuration` に adaptivePtime を有効化するフラグを追加し、音声送信トランシーバーの `RTCRtpEncodingParameters.adaptiveAudioPacketTime` に反映する。

後方互換性を維持するため、フラグのデフォルトは無効（`false`）とし、既存の挙動を変えない。映像向け `degradationPreference` の設定と同様に、音声送信トランシーバーの `sender.parameters` を取得して書き換える方式を採る。

実装の具体としては、`Sora/Configuration.swift` に音声向けフラグ（例: `var audioEnabledAdaptivePtime: Bool = false`）を追加し、`Sora/PeerChannel.swift:468` 付近の音声送信トランシーバー構成箇所で、フラグが有効な場合に `sender.parameters` を取得して各 `encodings` の `adaptiveAudioPacketTime` を `true` に設定し、`sender.parameters` に書き戻す。

## 完了条件

- `Configuration` に adaptivePtime を有効化するプロパティが追加されていること。
- 有効化時に、音声送信トランシーバーの `RTCRtpEncodingParameters.adaptiveAudioPacketTime` が `true` に設定されること。
- デフォルトでは無効であり、既存の挙動が変更されていない（後方互換が保たれている）こと。
- 設定が `sender.parameters` に反映されることを検証するテストを追加すること。
- `CHANGES.md` の `develop` セクションに以下を追記すること:
  ```
  - [ADD] adaptivePtime を設定できるようにする
    - @担当者
  ```

## 解決方法
