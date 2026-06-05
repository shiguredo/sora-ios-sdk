# 受信した映像フレームの生データを取得する API を追加する

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-video-frame-raw-data

## 目的

`VideoFrame` から映像フレームの生データ (`CVPixelBuffer`) を取得する API を追加する。これにより、受信映像を機械学習の入力や画像処理などに加工可能なデータとして利用できるようになる。現状は `RTCVideoFrame` の生データを取り出す手段が無く、生データを得るには `AVCaptureVideoDataOutput` のデリゲートを差し替えるようなトリッキーな手法が必要になる。

## 優先度根拠

- 具体的なユーザー要望ではなく、ユースケースの想定に基づく機能追加であり緊急性は低い。
- プロパティ追加のみの小さな機能拡張のため Low とする。

## 現状

`VideoFrame` から生データを取得する API が存在しない。`enum VideoFrame` は `case native` のみを定義しており、公開しているプロパティは `width` / `height` / `timestamp` だけで、フレームバッファーの生データを取り出すプロパティが無い。

```swift
// Sora/VideoFrame.swift:10-41
public enum VideoFrame {
  /// ネイティブの映像フレーム。
  /// `CMSampleBuffer` から生成した映像フレームは、ネイティブの映像フレームに変換されます。
  case native(capturer: RTCVideoCapturer?, frame: RTCVideoFrame)

  /// 映像フレームの幅
  public var width: Int {
    switch self {
    case .native(capturer: _, let frame):
      return Int(frame.width)
    }
  }

  /// 映像フレームの高さ
  public var height: Int {
    switch self {
    case .native(capturer: _, let frame):
      return Int(frame.height)
    }
  }

  /// 映像フレームの生成時刻
  public var timestamp: CMTime? {
    switch self {
    case .native(capturer: _, let frame):
      return CMTimeMake(value: frame.timeStampNs, timescale: 1_000_000_000)
    }
  }
```

`init?(from sampleBuffer:)` は `CMSampleBuffer` から `VideoFrame` を生成する方向の変換のみを提供しており、逆方向 (フレームから生データを取り出す) は提供していない。

```swift
// Sora/VideoFrame.swift:52-63
public init?(from sampleBuffer: CMSampleBuffer) {
  guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
    return nil
  }
  let timeStamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
  let timeStampNs = Int64(timeStamp * 1_000_000_000)
  let frame = RTCVideoFrame(
    buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer),
    rotation: RTCVideoRotation._0,
    timeStampNs: timeStampNs)
  self = .native(capturer: nil, frame: frame)
}
```

`RTCVideoFrame.buffer` は `RTCVideoFrameBuffer` プロトコルであり、`RTCCVPixelBuffer` にキャストすれば `CVPixelBuffer` を取得できる。また `RTCI420Buffer` 経由で I420 / YUV データも取得できる。

## 設計方針

- `VideoFrame` に生データを取り出す computed property を追加する。`RTCVideoFrame.buffer` をラップし、`RTCCVPixelBuffer` にキャストできる場合のみ `CVPixelBuffer` を返す。
- `CMSampleBuffer` は `CVPixelBuffer` から生成可能であり、その変換はユーザーに委ねる。I420 / YUV の取得は、必要に応じて `RTCVideoFrame.buffer` を `RTCI420Buffer` として取得する API を追加するが、まずは iOS API で扱いやすい `CVPixelBuffer` の取得を優先する。
- 既存の `case native` および各プロパティの挙動は変更せず、プロパティの追加のみを行う。後方互換性を維持する。

## 完了条件

- `VideoFrame` から `CVPixelBuffer` を取得できるプロパティが追加されている。
- `RTCCVPixelBuffer` にキャストできない場合は `nil` を返すこと。
- 既存の `width` / `height` / `timestamp` / `init?(from:)` の挙動が変更されていないこと (後方互換性が保たれている)。
- `CMSampleBuffer` から生成した `VideoFrame` で `CVPixelBuffer` が取得できることを検証するテストが `SoraTests/` に追加されている。
- `CHANGES.md` の `develop` セクションに以下を追記すること:
  ```
  - [ADD] VideoFrame に CVPixelBuffer を取得するプロパティを追加する
    - @担当者
  ```

## 解決方法
