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

## 根拠

Edge デバイス上での音声・映像処理は、ビデオ会議・配信のユーザー体験向上において重要度が増している。SDK がプロセッサーを差し込める構造を提供することで、利用者が独自の AI 処理や画像処理を組み合わせやすくなる。
