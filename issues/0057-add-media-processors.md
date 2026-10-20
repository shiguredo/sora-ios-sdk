# Media Processors 対応

- Priority: Low
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/add-media-processors
- Polished: 2026-09-24

## 概要

送信前の映像にリアルタイム処理（背景ぼかし・エフェクトなど）を適用できる Media Processors 機能を iOS SDK でサポートする。

音声プロセッサーは本 issue では対象外とする (「スコープ外」参照)。

## 方針

- 処理モジュールは SDK 本体に組み込まない
- 処理モジュールを差し替え可能な設計にし、利用者が独自のプロセッサーを実装・導入できるようにする
- 時雨堂の `shiguredo/media-processors`（ブラウザ向けの TypeScript ライブラリ）が使う技術スタックを参考にする。同リポジトリの virtual-background は MediaPipe Selfie Segmentation、noise-suppression は RNNoise (WASM) を使う

## 前提となる issue

- `0105` (closed): frame ingress (frame の受理、`VideoFilter` の実行 executor、上限超過の破棄、`terminate()` 後の破棄) は完了済みであり、`Sora/StreamFrameOwner.swift` の `StreamFrameOwner` と `BasicMediaStream.send(videoFrame:)` に実装されている。本 issue の processor はこの ingress の executor (owner queue) 上で frame ごとに直列に実行する
- `0070` (open): WebRTC C xcframework 移行と整合させる。同 issue は公開 API からの raw WebRTC 型の撤去を進めるため、本 issue で追加する公開 API に raw WebRTC 型を出さない

責務境界:

- frame の受理順、実行 executor、上限超過の破棄は `0105` の ingress が担う。本 issue の processor は「受理された frame をどう加工するか」だけを担い、順序と drop の判断を processor へ委ねない (`0105` の `VideoFilter` と同じ位置付け)
- processor の drop 契約は「加工を完了できなかった frame をどうするか」であり、`0105` の滞留上限による破棄とは別の契約として定義する
- 新しい公開 API に raw WebRTC 型 (`RTCVideoFrame` / `RTCVideoSource` など) を出さない。`0070` と衝突するため、processor の入出力は SDK の型で表現し、既存の `VideoFrame` を使う (processor 専用の値型は追加しない。`VideoFilter` も同じ `VideoFrame` を使っている)

## 対応内容

### SDK 側

映像フレームの処理を非同期かつ drop 可能にフックできるプロトコルを定義する。

```swift
// 映像フレームプロセッサーの例
public protocol VideoProcessor: AnyObject {
  func process(
    frame: VideoFrame,
    completion: @escaping (VideoFrame?) -> Void)
}
```

- `completion` に `nil` を渡すと frame が破棄される (drop 契約)。加工後の `VideoFrame` を渡すとその frame が送信される
- `process(frame:completion:)` は `0105` の ingress (owner queue) 上で frame ごとに直列に呼ばれる。同じ stream で同時に 2 つの frame が processor へ入ることはない。owner queue は completion を受けるまで次の frame へ進まない。completion は任意の executor から呼んでよい (process 内で同期的に呼んでもよい)
- `Configuration.videoProcessor` にプロセッサーを設定できる API を追加する。複数の加工を組み合わせたい場合は利用者が 1 つの processor に合成する (SDK はチェーンを提供しない)
- カメラキャプチャー・画面キャプチャ・利用者による直接送信は `0105` の ingress に統一されているため、processor はすべての入力元へ適用される
- 既存の `VideoFilter` (`MediaStream.videoFilter`) と併用する場合は、processor の後に実行される
- `Configuration.videoProcessor` は `ConnectionConfigurationSnapshot` (Sendable) には含めない。`MediaChannel` の designated init が `audioDevice` と同様に snapshot とは別の引数で受け取り、送信 stream 生成時に `BasicMediaStream` へ移す (接続開始時に 1 回だけ渡し、接続後は変更しない)

### 外部プロセッサーの参考実装

- ブラウザ向け `shiguredo/media-processors` の virtual-background (MediaPipe Selfie Segmentation) と noise-suppression (RNNoise WASM) を参考に、iOS 向けの実装を別途サンプルとして検討する
- モデルは利用者が差し替えられるように設計する
- 背景ぼかしは Apple の Vision だけでも実装できるため、MediaPipe を使わない選択肢も検討する

#### 背景ぼかし

Apple の Vision フレームワークが提供する `VNGeneratePersonSegmentationRequest` で人物領域のマスクを生成できる。2021 年 (iOS 15) に追加された API で、既存の画像や動画から人物を切り抜ける。追加のモデルを同梱せず iOS 標準 API だけで人物セグメンテーションを実行できるため、MediaPipe を使わない背景ぼかしの実装候補になる。

参考:

- Apple Developer Documentation `VNGeneratePersonSegmentationRequest`: https://developer.apple.com/documentation/vision/vngeneratepersonsegmentationrequest
- Qiita「iOS で人物きりぬき PersonSegmentation（バーチャル背景、背景ぼかし、合成）」: https://qiita.com/john-rocky/items/dc1b736791dccbaf5c66

実装上の検討事項:

- `VNGeneratePersonSegmentationRequest` は状態保持 (Stateful) のリクエストで、`VNSequenceRequestHandler` にフレームを順次渡して実行する。`qualityLevel` は `.fast` / `.balanced` / `.accurate` から選べ、精度と実行速度がトレードオフになる。ストリーミング用途は `.fast` が想定される
- 実行結果は人物マスクを保持する観測として返る (`VNPixelBufferObservation` の `pixelBuffer`)。`CIBlendWithMask` などで元フレームとぼかし背景を合成する。加工後のフレームは SDK の `VideoFrame` で返す (既存の `VideoFrame.init?(from:)` が `CMSampleBuffer` から生成できるため、`CVPixelBuffer` から `CMSampleBuffer` を組んで使う)
- マスク生成は重い処理のため、毎フレーム同期に処理すると映像送信経路 (owner queue) を滞留させ、`0105` の上限 (`maxPendingFrameCount = 4`) で frame が破棄される。processor 内部で非同期にマスクを生成し、生成中は直前のマスクで合成した frame を返す間引きを行う (間引きは processor 側の実装であり、SDK の契約ではない)
- 背景のぼかし処理は SDK 本体に組み込まず、利用者が差し込める processor として提供する。実機で処理時間・精度・消費電力を計測してから、サンプルの提供方法を決める

## スコープ外

- 音声プロセッサー。SDK には送信側の音声フレームを取得する ingress が存在しない (`MediaStream.addAudioTrackSink(_:)` は受信側の PCM 取得であり、送信側の音声は libwebrtc の ADM が取得する)。音声プロセッサーをサポートするには送信側の音声フレーム ingress の設計・実装が必要であり、本 issue では扱わない
- `MediaStream.videoFilter` の挙動変更。既存の `VideoFilter` は本 issue の完了後も変更しない

## 変更対象

- `Sora/VideoProcessor.swift` (新規): `VideoProcessor` プロトコル
- `Sora/Configuration.swift`: `Configuration.videoProcessor` の追加
- `Sora/MediaChannel.swift` / `Sora/PeerChannel.swift` / `Sora/MediaStream.swift`: snapshot とは別に受け取った processor を送信 stream (`BasicMediaStream`) へ引き渡す
- `Sora/StreamFrameOwner.swift`: processor の storage と、owner queue 上での実行 (completion の待ち合わせと drop の扱い)
- `skills/sora-ios-sdk/SKILL.md` / `CHANGES.md`: `VideoProcessor` / `Configuration.videoProcessor` の doc と変更履歴

## テスト方針

- モックやスタブは使用しない。テスト用の `VideoProcessor` 実装は実 protocol に対する観測用の実装とする (`0105` の `RecordingVideoFilter` と同じ方針)
- processor の直列実行、completion による drop、上限超過と `terminate()` 後の破棄 (`0105` の ingress 契約) との関係を `SoraTests/StreamFrameOwnerTests.swift` の拡張で検証する

## 完了条件

- `VideoProcessor` プロトコルと `Configuration.videoProcessor` が公開されていること
- processor が送信 stream の ingress (owner queue) 上で frame ごとに直列に実行され、completion の `nil` が drop として扱われ、`RTCVideoSource` へ配送されないこと (テストで検証する)
- processor の実行順序、`0105` の上限超過の破棄、`terminate()` 後の破棄が ingress の契約に従い、processor は順序と drop の判断をしないこと (テストで検証する)
- 新しい公開 API に raw WebRTC 型が露出していないこと
- 既存の `VideoFilter` (`MediaStream.videoFilter`) の挙動が変わっていないこと
- `skills/sora-ios-sdk/SKILL.md` と `CHANGES.md` に記載されていること

## 根拠

Edge デバイス上での音声・映像処理は、ビデオ会議・配信のユーザー体験向上において重要度が増している。SDK がプロセッサーを差し込める構造を提供することで、利用者が独自の AI 処理や画像処理を組み合わせやすくなる。
