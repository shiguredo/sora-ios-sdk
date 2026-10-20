# カメラ以外の映像入力ソースに対応する

- Priority: Medium
- Created: 2026-06-06
- Completed: 2026-09-24
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

## 解決方法

本 issue の主要な目的（画面キャプチャーを SDK が映像取得から配信まで一貫して担う API として提供する）は実装済み・リリース済みであり、残る検討事項は他 issue へ分割済みまたは対応しないと確定しているため closed にする。

- 画面キャプチャー (ReplayKit / `RPScreenRecorder`) は実装・リリース済み
  - コミット「画面キャプチャ機能を追加」(`324add4`、PR #312、マージ `9a84c9d` 2026-02-24) で実装され、`CHANGES.md` の `[ADD] iOS 端末画面をキャプチャして配信する ScreenCapture を追加する` として 2026.2.0 (リリース日 2026-07-29) でリリース済み
  - 公開 API: `MediaChannel.startScreenCapture(settings:)` / `MediaChannel.stopScreenCapture()` / `MediaChannel.isScreenCaptureActive()`、設定型 `ScreenCaptureSettings` (targetFPS、videoSampleBufferTransformer)。本体は `Sora/ScreenCapture.swift` の `ScreenCaptureController` / `ScreenCaptureRecorderCoordinator`
  - 以後も保守が続いており、`issues/closed/0097-bug-fix-screen-capture-frame-generation.md` と `issues/closed/0104-refactor-screen-capture-buffer-ownership.md` が完了し、`issues/0137-bug-fix-screen-capture-recorder-orphan.md` (open) が現行の問題を扱っている
- アプリ音声: 実装時に確認され、ReplayKit 経路のマイク / カメラ入力は使わないと明文化されている (`Sora/ScreenCapture.swift` の `ScreenCaptureController` 内コメント「本 API は画面映像のみを送信対象としており、ReplayKit 経路でのマイク / カメラ入力は使用しません」、`recorder.isMicrophoneEnabled = false`)
- 映像入力ソースの抽象化: 公開プロトコル (Issue に例示された `VideoSource` 相当) としては実装されていないが、SDK 内部に `VideoSourceCoordinator` (`Sora/CameraVideoCapturer.swift`) による `ScreenCaptureController` / `CameraVideoCapturer` の所有・排他調整 (screen 予約と camera 予約の排他) が実装されており、設計方針の目的 (カメラ / 画面キャプチャーの共存制御) は達成されている
- 接続時自動開始: 実装では画面共有は接続後に利用者が明示的に開始する API として提供され、`skills/sora-ios-sdk/SKILL.md` の画面キャプチャ節に「同一送信ストリームでカメラと画面キャプチャは同時に使えない。`initialCameraEnabled = false` にするか、`setVideoHardMute(true)` でカメラを止めてから開始する」と運用が明記されている。カメラと同じ接続時自動開始設定は用意されていないが、画面共有をユーザー操作なしに自動開始しない設計として確定している
- 低レベル API: `VideoFrame(from: CMSampleBuffer)` (`Sora/VideoFrame.swift`) と `MediaStream.send(videoFrame:)` により外部フレームの送信経路が既に存在し、`ScreenCaptureSettings.videoSampleBufferTransformer` で `CMSampleBuffer` の変換も可能。本 issue では「将来的に検討」とされており、必須の作業ではない
- 外部カメラ: 分割済み。`issues/0143-add-ipad-external-camera.md` (open) が「カメラ以外の映像入力ソースの抽象化 (0053) とは別に、既存の `CameraVideoCapturer` の枠組みで外部カメラを扱う」と明記している
- Broadcast Upload Extension: `issues/0061-add-app-extension-support.md` (open) が、現在の `RPScreenRecorder` ベースの実装は `RPBroadcastSampleHandler` を使う別アーキテクチャであり、本格対応は 0061 のスコープ外と明記している。本 issue の「考慮する」事項はこの方針で確定している
- 仮想カメラ: iOS で利用者が利用可能な仮想カメラデバイスを提供する手段はなく、デマンドも確認できないため対応対象としない
