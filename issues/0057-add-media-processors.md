# Media Processors 対応

- Priority: Low
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/add-media-processors
- Polished:

## 概要

送信前の音声・映像にリアルタイム処理（ノイズ抑制・背景ぼかし・エフェクトなど）を適用できる Media Processors 機能を iOS SDK でサポートする。

## 方針

- 処理モジュールは SDK 本体に組み込まない
- 処理モジュールを差し替え可能な設計にし、利用者が独自のプロセッサーを実装・導入できるようにする
- 時雨堂の `media-processors` が使う技術スタックを参考にする

## 対応内容

### SDK 側

映像・音声フレームの処理をフックできるプロトコルを定義する。

```swift
// 映像フレームプロセッサーの例
public protocol VideoProcessor {
    func process(frame: RTCVideoFrame) -> RTCVideoFrame?
}

// 音声フレームプロセッサーの例
public protocol AudioProcessor {
    func process(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer?
}
```

- `Configuration` にプロセッサーを設定できる API を追加する
- カメラキャプチャーと映像送信の間にプロセッサーを差し込む処理フローを実装する

### 外部プロセッサーの参考実装

- MediaPipe（iOS 対応）を使ったノイズ抑制・背景ぼかし実装を別途サンプルとして検討する
- モデルは利用者が差し替えられるように設計する
- 背景ぼかしは Apple の Vision だけでも実装できるため、MediaPipe を使わない選択肢も検討する

#### 背景ぼかし

Apple の Vision フレームワークが提供する `VNGeneratePersonSegmentationRequest` で人物領域のマスクを生成できる。2021 年に追加された API で、既存の画像や動画から人物を切り抜ける。追加のモデルを同梱せず iOS 標準 API だけで人物セグメンテーションを実行できるため、MediaPipe を使わない背景ぼかしの実装候補になる。

参考:

- Apple Developer Documentation `VNGeneratePersonSegmentationRequest`: https://developer.apple.com/documentation/vision/vngeneratepersonsegmentationrequest
- Qiita「iOS で人物きりぬき PersonSegmentation（バーチャル背景、背景ぼかし、合成）」: https://qiita.com/john-rocky/items/dc1b736791dccbaf5c66

実装上の検討事項:

- `VNGeneratePersonSegmentationRequest` は状態保持 (Stateful) のリクエストで、`VNSequenceRequestHandler` にフレームを順次渡して実行する。`qualityLevel` は `.fast` / `.balanced` / `.accurate` から選べ、精度と実行速度がトレードオフになる。ストリーミング用途は `.fast` が想定される
- 実行結果は人物マスクの `CVPixelBuffer` で返る。`CIBlendWithMask` などで元フレームとぼかし背景を合成する
- マスク生成は重い処理のため、同期の `VideoFilter.filter(videoFrame:)` から毎フレーム呼ぶと映像送信経路をブロックする。非同期処理とフレーム drop を扱えるプロセッサー契約で実行し、生成中は直前のマスクを再利用する間引きを検討する
- 背景のぼかし処理は SDK 本体に組み込まず、利用者が差し込める processor として提供する。実機で処理時間・精度・消費電力を計測してから、サンプルの提供方法を決める

## 根拠

Edge デバイス上での音声・映像処理は、ビデオ会議・配信のユーザー体験向上において重要度が増している。SDK がプロセッサーを差し込める構造を提供することで、利用者が独自の AI 処理や画像処理を組み合わせやすくなる。
