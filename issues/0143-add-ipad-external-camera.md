# iPad の外部 USB カメラに対応する

- Created: 2026-09-10
- Completed: {YYYY-MM-DD}
- Branch: feature/add-ipad-external-camera
- Polished: {YYYY-MM-DD}
- Reporter: @miosakuma

## 目的

iPadOS 17.0 以降の iPad では USB 接続の UVC 外部カメラが利用できる。 Sora iOS SDK でも外部カメラを映像入力ソースとして選択し、通常のカメラと同じように配信できるようにする。

現状はアプリ側で `CameraVideoCapturer` の生成、送信ストリームへの接続、開始と停止をすべて自前で管理しないと外部カメラを利用できない。

## 現状

- `Sora/CameraVideoCapturer.swift` の `CameraVideoCapturer.devices` は `RTCCameraVideoCapturer.captureDevices()` をそのまま返す。 libwebrtc の `RTCCameraVideoCapturer.captureDevices()` は `AVCaptureDeviceTypeBuiltInWideAngleCamera` のみを列挙するため、外部カメラが一覧に含まれない (libwebrtc M154 時点) 。
  - 一方で `RTCCameraVideoCapturer.startCapture(with:format:fps:)` は任意の `AVCaptureDevice` を扱えるため、外部カメラの起動自体は技術的には可能である。
- 接続時のカメラ選択は `CameraSettings.position` (`.front` / `.back`) のみである。 外部カメラの `AVCaptureDevice.position` は `.unspecified` になるため、 `Sora/PeerChannel.swift` の `initializeCameraVideoCapture` では外部カメラを選択できない (`.unspecified` はエラーとして扱われる) 。
- `MediaChannel.setVideoHardMute(_:)` の解除時のカメラ再起動も `CameraSettings.position` からカメラを選ぶ (`Sora/VideoMute.swift` の `startCameraVideoCapture`) 。 外部カメラではハードミュートを利用できない。
- アプリ側で `AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)` を使うと外部カメラの `AVCaptureDevice` を取得できることは実機で確認済みである。 ただし、そのデバイスを SDK の接続フローへ渡す公開 API がなく、 `CameraVideoCapturer(device:)` と `MediaChannel.senderStream` を組み合わせた手動運用では接続時の初期化、切断時の停止、ハードミュートをアプリが管理することになる。

## 設計方針

- `CameraVideoCapturer.devices` に外部カメラを含める。 `RTCCameraVideoCapturer.captureDevices()` の結果へ `AVCaptureDevice.DiscoverySession` で取得した `.external` のデバイスを `uniqueID` の重複を除いて追加する。
  - `AVCaptureDevice.DeviceType.external` は iOS 17.0 以降でのみ利用できるため `#available(iOS 17.0, *)` で分岐する。 SDK の最小対応バージョン (iOS 14) は変更しない。
- `CameraSettings` に `deviceID: String?` を追加する。 `AVCaptureDevice.uniqueID` を指定する API とし、指定時は `position` より優先する。 外部カメラは `position` で特定できないため、外部カメラを使う場合は `deviceID` を指定する。
  - `CameraSettingsSnapshot` にも `deviceID` を追加する。 `CameraSettings` 自体は `Sendable` にせず、actor 境界へ渡す値だけをスナップショット化する現行方針を維持する。
  - `PeerChannel.initializeCameraVideoCapture` と `VideoMute.startCameraVideoCapture` の両方で `deviceID` から `CameraVideoCapturer.devices` を検索し、見つかった `AVCaptureDevice` から `CameraVideoCapturer(device:)` を生成する。 `deviceID` が未指定の場合は現状どおり `position` から front / back を選ぶ。
  - `deviceID` に一致するデバイスが見つからない場合は、 front / back が見つからない場合と同じくカメラを起動せずにエラーログを出力する。
- `CameraVideoCapturer.flip(_:completionHandler:)` は `device.position` が `.front` / `.back` 以外の場合はエラーを返す。 外部カメラには front / back の区別がないため。
- 外部カメラは物理的に回転させられるため、回転補正に `AVCaptureDevice.RotationCoordinator` などが必要になる可能性がある。 本 issue では外部カメラの選択と送信までを対応し、回転補正は実機確認の結果に応じて別 issue で扱う。
- カメラ以外の映像入力ソースの抽象化 (0053) とは別に、既存の `CameraVideoCapturer` の枠組みで外部カメラを扱う。
- 公開 API の doc コメントと sora-ios-sdk-doc の `camera.rst` に、外部カメラは iOS / iPadOS 17.0 以降で利用できることと `deviceID` の指定方法を追記する。
- `CHANGES.md` に ADD として記載する。

## テスト方針

- `CameraSettings.deviceID` の設定と取得、`CameraSettingsSnapshot` が `deviceID` を保持することを `SoraTests` で検証する。 モックやスタブは使用しない。
- 外部カメラの列挙、選択、送信、ハードミュート、`flip` のエラーは Simulator では確認できないため、 iPadOS 17.0 以降の実機 iPad と USB 外部カメラで確認する。
- `deviceID` を指定しない場合の front / back の接続、`flip`、ハードミュートが変わらないことを既存テストと実機で確認する。
- iOS 16 以前の実機または Simulator で外部カメラ向けの分岐が無効になり、既存の挙動が変わらないことを確認する。

## 完了条件

- iPadOS 17.0 以降の iPad に外部カメラを接続したとき、`CameraVideoCapturer.devices` に外部カメラが含まれること。
- `CameraSettings.deviceID` に外部カメラの `uniqueID` を指定して接続すると、外部カメラの映像が送信されること。
- `MediaChannel.setVideoHardMute(_:)` が外部カメラで動作すること。
- 外部カメラで `CameraVideoCapturer.flip(_:completionHandler:)` を実行するとエラーになり、クラッシュしないこと。
- `deviceID` を指定しない場合の front / back の挙動と、iOS 16 以前の挙動が変わらないこと。
- 公開 API の doc コメントを追加すること。
- `CHANGES.md` に追加を記載すること。

## 変更対象ファイル

- `Sora/CameraVideoCapturer.swift`
- `Sora/PeerChannel.swift`
- `Sora/VideoMute.swift`
- `SoraTests/` (追加するテスト)
- `CHANGES.md`

## 解決方法
