# Configuration.videoBitRate に大きい値を設定すると H.264 エンコーダーがクラッシュする

- Priority: High
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/fix-h264-encoder-crash-high-bitrate
- Polished:

## 概要

`Configuration.videoBitRate` に大きい値（例: 20000）を設定すると、iOS のハードウェア H.264 エンコーダーがクラッシュする。H.265 エンコーダーでは同値を設定してもクラッシュしない。

## 再現手順

```swift
// クラッシュする設定例
configuration.videoBitRate = 20000
configuration.cameraSettings = CameraSettings(resolution: .vga480p, frameRate: 30, position: .back)
```

```swift
// クラッシュしない設定例
configuration.videoBitRate = 15000
configuration.cameraSettings = CameraSettings(resolution: .vga480p, frameRate: 30, position: .back)
```

## エラーログ

`Sora.setWebRTCLogLevel(.verbose)` を設定すると以下のエラーが出力される。

```
libwebrtc ERROR: (RTCVideoEncoderH264.mm:769): H264 encode failed with code: -12902
```

## 確認済み環境

- iPad Pro 11-inch および iPad Pro 12 Max
- libwebrtc M116、M119

## 補足

端末によってクラッシュが発生する閾値が異なる可能性がある。

## 根拠

エンコーダーのクラッシュはアプリ強制終了を引き起こす致命的な不具合。H.264 は広く使われるコーデックであり、高ビットレートを指定した際に無条件でクラッシュするのは許容できない。

## 対応方針

- iOS の HW H.264 エンコーダーが受け付けるビットレート上限を調査する
- SDK 側でビットレートの上限チェックまたはキャップを実装するか検討する
- あるいは libwebrtc 側の `RTCVideoEncoderH264.mm` の動作を確認し、回避策を検討する
