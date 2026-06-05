# 配信時の発熱を調査する

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/investigate-streaming-thermal

## 目的

Sora iOS SDK を用いた映像配信時に端末が発熱する事象の原因を調査する。発熱の主要因（映像エンコード、カメラキャプチャ、フレームレート、解像度、サイマルキャスト、ネットワーク再送など）を実機で測定して切り分け、どの処理がどの程度の発熱・電力消費に寄与しているかを把握し、対策方針を決定する。本 issue は実装ではなく調査タスクである。

## 優先度根拠

- 発熱は配信時間や端末寿命・ユーザー体験に直結する実利用上の課題であり、原因の切り分けが対策の前提となる。
- 即時のバグ修正ではなく調査フェーズであるため High ではなく Medium とする。

## 現状

発熱に関与しうる主な処理は以下に存在するが、発熱の定量的な測定・切り分けは行われていない。

カメラキャプチャとフォーマット選択は `CameraVideoCapturer` で行っている。

```swift
public static func format(
  ...
)
public static func maxFrameRate(_ frameRate: Int, for format: AVCaptureDevice.Format) -> Int? {
```

`Sora/CameraVideoCapturer.swift:56` の `format` と `Sora/CameraVideoCapturer.swift:90` の `maxFrameRate` で解像度・フレームレートを選択している。カメラ設定は `Configuration` で指定する。

```swift
public var cameraSettings = CameraSettings.default
```

`Sora/Configuration.swift:122` の `cameraSettings` で解像度・フレームレート等を指定する。映像エンコードまわりは libwebrtc 本体に委ねられており、現在の libwebrtc は `Sora/PackageInfo.swift` の `WebRTCInfo.version`（M148 系）である。

発熱の原因が SDK 設定（解像度・フレームレート・サイマルキャスト等）にあるのか、libwebrtc のエンコード処理にあるのか、ハードウェアエンコーダの利用可否にあるのかが切り分けられていない。

## 設計方針

実機を用いた測定により発熱要因を切り分ける。

- 測定環境
  - 実機（複数世代の iPhone / iPad）で測定する。シミュレータは発熱・電力特性が実機と異なるため使用しない。
  - 配信解像度・フレームレート・サイマルキャスト有無・コーデック・接続時間を固定した再現可能なシナリオを用意する。
- サーマルステートの観測
  - `ProcessInfo.processInfo.thermalState` を一定間隔でサンプリングし、`nominal` / `fair` / `serious` / `critical` の遷移と経過時間を記録する。
  - `ProcessInfo.thermalStateDidChangeNotification` を購読して状態遷移のタイミングを記録する。
- 電力・負荷の観測
  - Xcode Instruments の Energy Log / Time Profiler、Xcode の Energy Impact ゲージで CPU・GPU・ネットワークの消費を観測する。
  - ハードウェアエンコーダ（VideoToolbox）が使われているか、ソフトウェアエンコードにフォールバックしていないかを確認する。
- 変数を切り分けた比較測定
  - 解像度・フレームレートを段階的に変えて発熱への寄与を比較する。
  - サイマルキャストの有無、コーデック（H.264 / VP8 / VP9 / AV1）の違いで比較する。
  - 映像なし（音声のみ）配信との比較でカメラ・エンコードの寄与を切り分ける。

本 issue は調査タスクであり、SDK のコード変更は行わない（測定用の検証コードは別途用意してよいが本 issue の成果物には含めない）。

## 完了条件

- 実機での測定により、発熱の主要因が解像度・フレームレート・サイマルキャスト・コーデック・エンコーダ種別のいずれにどの程度寄与しているかが切り分けられていること。
- サーマルステートの遷移と経過時間が条件別にまとめられていること。
- 調査結果のまとめと今後の対策方針（設定の見直し、libwebrtc 側の調整、推奨設定の提示など）が決定され、本 issue にまとめられていること。

## 解決方法
