# VideoFrame に pixelBuffer プロパティを追加する

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-video-frame-raw-data
- Polished: 2026-06-05

## 目的

`VideoFrame` から映像フレームの生データ（`CVPixelBuffer`）を取得する `pixelBuffer` プロパティを追加する。これにより、`CMSampleBuffer` 経由で生成したフレームや `RTCCVPixelBuffer` として格納されたフレームを、機械学習の入力や画像処理などに加工可能なデータとして利用できるようになる。

**注意**: WebRTC がネットワーク経由で受信してソフトウェアデコードしたフレームのバッファ型は `RTCI420Buffer`（YUV I420）であり、この場合 `pixelBuffer` は `nil` を返す。本 issue のスコープは `RTCCVPixelBuffer` として格納されているフレームのみを対象とし、`RTCI420Buffer` の `CVPixelBuffer` への変換は別 issue として扱う。

## 優先度根拠

- 具体的なユーザー要望ではなく、ユースケースの想定に基づく機能追加であり緊急性は低い。
- プロパティ追加のみの小さな機能拡張のため Low とする。

## 現状

`VideoFrame` から生データを取得する API が存在しない。`enum VideoFrame` は `case native` のみを定義しており、公開しているプロパティは `width` / `height` / `timestamp` だけで、フレームバッファーの生データを取り出すプロパティが無い（`Sora/VideoFrame.swift:10-41`）。

`init?(from sampleBuffer:)`（`Sora/VideoFrame.swift:52-63`）では `RTCCVPixelBuffer(pixelBuffer:)` で明示的にラップしているため、`CMSampleBuffer` 経由で生成した `VideoFrame` のバッファは常に `RTCCVPixelBuffer` になる。一方、ネットワーク受信フレームのバッファ型は WebRTC のデコード処理に依存しており、`RTCI420Buffer` になる場合がある。

`RTCVideoFrame.buffer` は `RTCVideoFrameBuffer` プロトコルであり、`RTCCVPixelBuffer` にキャストすれば `.pixelBuffer` プロパティ（`CVPixelBuffer` 型）を取得できる。

## 設計方針

1. `Sora/VideoFrame.swift` の `// MARK: - プロパティ` セクション内、`timestamp` プロパティ（40 行目）の直後に `public var pixelBuffer: CVPixelBuffer?` を追加する。既存の `width` / `height` / `timestamp` と同様の `switch self` パターンで実装する。
2. 実装は `frame.buffer as? RTCCVPixelBuffer` でキャストし、成功した場合は `.pixelBuffer` を返し、失敗した場合は `nil` を返す。これにより `RTCI420Buffer` を持つフレーム（ネットワーク受信時等）では `nil` を返すが、API の動作として明文化する。
3. 既存の `case native` および各プロパティの挙動は変更せず、プロパティの追加のみを行う。後方互換性を維持する。

## テスト方針

モック・スタブは使用しない。`CMSampleBuffer` から生成した `VideoFrame` は `RTCCVPixelBuffer` を持つため、実際の `CVPixelBuffer` を使った純粋なユニットテストで検証できる。

以下をテストする:

- `CMSampleBuffer` から生成した `VideoFrame` の `pixelBuffer` が非 `nil` であること。
- 取得した `CVPixelBuffer` のサイズ（幅・高さ）が `VideoFrame.width` / `height` と一致すること。

テストの追加先は新規ファイル `SoraTests/VideoFrameTests.swift` を作成すること（`SoraTests/` 配下に `VideoFrame` 向けテストファイルは存在しない）。テスト用の `CMSampleBuffer` は `CVPixelBufferCreate` と `CMSampleBufferCreateReadyWithImageBuffer`（iOS 14 でも利用可能）を使って生成できる（外部依存なし）。なお `CVPixelBufferGetWidth` / `CVPixelBufferGetHeight` はロックなしで呼び出せる。

`RTCI420Buffer` を持つフレームで `nil` を返すことの自動テストは、モック不使用制約下では `RTCI420Buffer` を直接生成する手段がないため現スコープでは対象外とする。完了条件での「nil を返す」挙動の確認はコードレビューで担保する。

## 完了条件

- `VideoFrame` に `public var pixelBuffer: CVPixelBuffer?` プロパティが追加されること。
- `RTCCVPixelBuffer` を持つフレームでは `CVPixelBuffer` を返し、`RTCI420Buffer` を持つフレームや不明バッファの場合は `nil` を返すこと。
- 既存の `width` / `height` / `timestamp` / `init?(from:)` の挙動が変更されていないこと（後方互換）。
- テスト方針に記載したテストがすべて通ること。
- `CHANGES.md` の `develop` セクションに以下の形式で追記すること:

```
- [ADD] `VideoFrame.pixelBuffer` を追加して CVPixelBuffer を取得できるようにする
  - @voluntas
```

## 解決方法
