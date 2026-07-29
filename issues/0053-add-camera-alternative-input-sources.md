# カメラ以外の映像入力ソースに対応する

- Priority: Medium
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/add-camera-alternative-input-sources
- Polished:

## 概要

現状はカメラのみを映像入力ソースとしてサポートしているが、画面キャプチャー（Screen Capture）など他の入力ソースにも対応し、SDK が映像取得から配信までを一貫して担う API を提供する。

## 背景

現在は `MediaChannel.senderStream.send()` に `VideoFrame` を渡すことでカメラ以外の映像を送ることは技術的に可能だが、ユーザーが自前で映像取得・フレーム変換まで実装しなければならない。SDK 側で典型的な入力ソースを扱う仕組みを持つことで利用者の実装コストを大幅に下げられる。

他の SDK（SkyWay iOS SDK、LiveKit iOS SDK）は ReplayKit を使った画面共有や Bitmap 入力に対応しており、Sora iOS SDK でも同等の機能を提供することが求められている。

## 対応候補

### 画面キャプチャー（優先度高）

- ReplayKit フレームワーク（`RPScreenRecorder`）を利用した画面共有
- カメラと同様に接続時開始・任意の `start` / `stop` が行える API にする
- アプリ音声も合わせて送れるかどうか確認する

### その他（将来的に検討）

- `CVPixelBuffer` / `CMSampleBuffer` を直接渡す低レベル API の整備
- 外部カメラ・仮想カメラ等の対応

## 設計方針

- 映像入力ソースを抽象化したプロトコル（`VideoSource` など）を定義し、カメラ・画面キャプチャーを実装として持つ
- 既存の `CameraVideoCapturer` と同等の操作性（`start`、`stop`、接続時自動開始）を提供する
- `ReplayKit` を使う実装は `Broadcast Upload Extension` での利用も考慮する

## 根拠

画面共有はビデオ会議・教育・サポート用途で需要が高い機能。SDK がサポートすることでユーザーの実装コストが大幅に下がる。
