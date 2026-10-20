# iOS 27 以降の ScreenCaptureKit に対応する

- Created: 2026-10-20
- Completed: {YYYY-MM-DD}
- Branch: feature/add-screen-capture-kit
- Polished: {YYYY-MM-DD}
- Priority: Medium

## 目的

iOS 27 で ReplayKit の画面キャプチャ API が非推奨になり、ScreenCaptureKit (以下 SCK) が移行先として示された。SDK の現行画面キャプチャは `RPScreenRecorder` に依存しており、iOS 27 以降では非推奨 API の上に残る。また、ReplayKit のアプリ内キャプチャは自アプリの画面のみを対象とし、他アプリを含む全画面共有には Broadcast Upload Extension が必要だが、SDK はこの構成を提供していない。SCK の `SCContentSharingPicker` を使えば、拡張ターゲットなしで全画面・ウィンドウ共有を実現できる。iOS 27 以降の環境で、この経路を SDK の公開 API として提供する。

## 現状

- `Sora/ScreenCapture.swift` の `ScreenCaptureController` は `RPScreenRecorder.shared()` を使い、`startCapture` / `stopCapture` で画面映像のみを取得する。`RPScreenRecorder` はアプリ内の画面を対象とするため、他アプリやホーム画面は取得できない。`recorder.isMicrophoneEnabled` と `recorder.isCameraEnabled` は false にしている。
- 公開 API は `MediaChannel.startScreenCapture(settings:)` / `stopScreenCapture()` / `isScreenCaptureActive()`。`ScreenCaptureSettings` は `targetFPS`、`videoSampleBufferTransformer`、`onRuntimeError` を持つ。
- フレームは `ScreenCaptureOwnedSampleBuffer` → `ScreenCaptureOwnedFrame` → `sendVideoFrameQueue` → `MediaStream.send(videoFrame:)` の経路で送る。`captureID` の世代照合、`targetFPS` の PTS 間引き、送信中のフレーム破棄、所有権の移動が実装されている。
- `Package.swift` の deployment target は iOS 14。開発環境は Xcode 26.6 / iphoneos26.5 に固定されている (`Makefile`、`.github/workflows/build.yml` など)。
- `VideoFrame(from: CMSampleBuffer)` と `MediaStream.send(videoFrame:)` は公開されているため、利用者が自前で SCK を実装することは可能。ただし、カメラとの排他、`targetFPS`、`videoSampleBufferTransformer`、停止・切断時の後始末は利用者の責任になる。

## iOS 27 SDK で確認した SCK の仕様

- SCK は iOS 27.0 以降で利用できる。`SCShareableContent` / `SCDisplay` / `SCWindow` / `SCRunningApplication` は iOS では利用不可で、コンテンツ選択は `SCContentSharingPicker` に限られる。
- `SCContentSharingPicker.present()` はシステムのコンテンツ共有ピッカーを表示する。`presentForCurrentApplication()` は自アプリのウィンドウ・レイヤーに限定する。選択結果は `SCContentSharingPickerObserver` の `contentSharingPicker(_:didUpdateWith:for:)` で `SCContentFilter` として返る。
- `SCStreamConfiguration.minimumFrameInterval` と `pixelFormat` は iOS では利用不可。フレームレートの抑制は受信側で行う必要がある。`width` / `height` / `capturesAudio` / `sampleRate` / `channelCount` / `excludesCurrentProcessAudio` は iOS 27 で利用できる。
- `SCStream.updateContentFilter` / `updateConfiguration` は iOS では利用不可。設定変更はストリームの作り直しになる。
- `SCStreamOutputType.audio` と `.microphone` は iOS 27 で利用できる。マイクの有効化は `SCContentSharingPickerConfiguration.showsMicrophoneControl` で行う。`SCStreamConfiguration.captureMicrophone` は iOS では利用不可。
- `SCStreamError.userDeclined` / `userStopped` / `missingBackgroundMode` / `notSupported` が iOS 27 向けに定義されている。`missingBackgroundMode` は `UIBackgroundModes` に `screen-capture` がない場合にストリームが停止することを示す。
- Apple の iOS 向けサンプルは、全画面キャプチャのバックグラウンド継続のために `UIBackgroundModes` に `screen-capture` を、マイクを使う場合に `audio` を追加するよう案内している。カメラオーバーレイ (`SCVideoEffectOutput`) はアプリ内キャプチャのみで、全画面キャプチャでは使えない。
- ReplayKit の `RPScreenRecorder` / `startCapture` / `RPBroadcastSampleHandler` / `RPSystemBroadcastPickerView` は iOS 27 で非推奨。移行先は SCK。

## 設計方針

### スコープ

- 映像のみを対象とする。SCK の音声出力を SDK の音声パイプライン (ADM / AVAudioSession) に注入する公開経路がないため、`capturesAudio = false` とし、システム音声の送出は別 issue とする。
- iOS 27.0 以降でのみ利用できる新しい公開 API を追加する。既存の `startScreenCapture(settings:)` は iOS 14-26 の ReplayKit 経路として維持し、iOS 27 以降でも明示的に選べるようにする。
- Xcode 27 / iphoneos27.1 への更新を前提とする。SCK のシンボルは Xcode 27 SDK にしかないため、CI の toolchain 更新なしにはビルドもテストもできない。Xcode 27 への更新は別 issue で扱う。

### 公開 API

`ScreenCaptureTarget` (仮称) を追加し、既存 API のオーバーロードとして提供する。

```swift
@available(iOS 27.0, *)
public enum ScreenCaptureTarget {
  /// 自アプリのウィンドウ・レイヤーを対象にする (presentForCurrentApplication)
  case currentApplication
  /// システムのコンテンツ共有ピッカーで全画面またはウィンドウを選ぶ (present)
  case systemPicker
}

extension MediaChannel {
  @available(iOS 27.0, *)
  public func startScreenCapture(
    target: ScreenCaptureTarget,
    settings: ScreenCaptureSettings = .init()
  ) async throws
}
```

- 既存の `startScreenCapture(settings:)` は変更しない。iOS 27 で既定の経路を切り替えると、ピッカー UI の有無という利用者に見える挙動が変わるため、明示的な API にする。
- ピッカーの表示、`SCContentFilter` の取得、`SCStream` の生成と開始は SDK が行い、SCK の型を公開 API に露出しない。
- `ScreenCaptureSettings` に target を追加する案、`SCContentFilter` を受け取る低レベル API 案も検討したが、前者は設定型に UI の概念が混ざり、後者は SDK の導入コスト削減という目的に反するため採用しない。

### 内部構造

- `ScreenCaptureController` のフレーム送出部分 (capture ID の世代照合、`targetFPS` の間引き、`videoSampleBufferTransformer`、`MediaStream.send(videoFrame:)`) をバックエンド非依存のコアとして切り出し、ReplayKit と SCK のバックエンドを差し込む。
- SCK バックエンドは `SCContentSharingPickerObserver`、`SCStreamOutput`、`SCStreamDelegate` を実装する。ピッカーの observer は選択が返るまで保持し、最初の選択を受けたらピッカーから remove する。ストリーム開始後の選択変更は初版では扱わない。
- ピッカーの表示は MainActor で行い、observer と `SCStreamOutput` の callback は SDK の直列キューへ渡す。capture 状態の読み書きは lock 区間内に閉じ、ReplayKit callback と同じ隔離方針にする。
- `SCStreamOutput` の sample buffer は `SCFrameStatus` を見て `.complete` と `.started` のみを送出する。`.idle` / `.blank` / `.suspended` / `.stopped` は送出しない。
- `SCStreamFrameInfo.videoOrientation` を `RTCVideoRotation` に変換する。現行の `VideoFrame(from:)` は rotation 0 固定なので、向きを指定できる initializer を追加するか、SCK 側で `RTCVideoFrame` を組み立てる。
- `SCStreamConfiguration.width` / `height` は既定 (ネイティブ解像度) のままとする。解像度の上限が必要になった場合は `ScreenCaptureSettings` に追加する別 issue とする。
- `SCStreamConfiguration.capturesAudio = false`、`SCContentSharingPickerConfiguration.showsMicrophoneControl = false`、`showsCameraControl = false` を設定する。SDK のマイク・カメラ経路と二重にならないようにする。
- `SCContentSharingPicker.shared` はアプリ全体で共有される singleton であり、`defaultConfiguration` と `isActive` も共有される。SDK がこれらを変更するとホストアプリのピッカー利用と干渉するため、既存の `ScreenCaptureRecorderCoordinator` と同様の process-wide な coordinator で、ピッカーの利用権と設定の復元を管理する。最初は 1 プロセス 1 ストリームに制限する。
- ピッカーのキャンセル (`contentSharingPicker(_:didCancelFor:)`) は開始失敗として扱い、`SoraError.mediaChannelError` を throw する。ストリームの実行時停止 (`stream(_:didStopWithError:)`) は `ScreenCaptureSettings.onRuntimeError` に通知し、`isScreenCaptureActive()` が false になるよう状態を更新する。自動停止は行わない (既存の `onRuntimeError` の契約に合わせる)。
- `MediaChannel` の切断時は既存の `stopCaptureForDisconnect` 経路で SCK ストリームも停止する。
- 開始の各段階 (ピッカー表示、選択、ストリーム生成、出力追加、開始) で失敗した場合は、作成済みの `SCStream` を確実に停止してから throw する。既存の ReplayKit 経路の「start 失敗時に recorder を残さない」不変条件と同じ扱いにする。
- `SCStreamError.missingBackgroundMode` はアプリの `Info.plist` 設定不足として、原因と `UIBackgroundModes` の設定方法をエラーメッセージに含める。

## 変更対象

- `Sora/ScreenCapture.swift`: SCK バックエンド、ピッカー observer、ストリーム出力、状態管理
- `Sora/MediaChannel.swift`: `startScreenCapture(target:settings:)` と停止経路
- `Sora/VideoFrame.swift`: 向きを指定できる initializer (必要な場合)
- `SoraTests/`: フレーム状態のフィルタリング、向き変換、停止・再開始の世代管理のテスト
- `README.md`、`skills/sora-ios-sdk/SKILL.md`: iOS 27 以降の要件、`UIBackgroundModes`、システム音声非対応、既存 API との使い分け
- `CHANGES.md`: 変更履歴
- `TestConsumers/Swift6Consumer/ApiBaseline/`: 公開 API 追加に伴う baseline の再生成

## 完了条件

- iOS 27 実機で、`target: .systemPicker` により全画面または他アプリのウィンドウを選び、その映像が Sora へ送信できる。
- iOS 27 実機で、`target: .currentApplication` により自アプリの画面を送信できる。
- iOS 14-26 では既存の `startScreenCapture(settings:)` が従来どおり ReplayKit で動作する。
- SCK 経路でも `targetFPS` の間引き、`videoSampleBufferTransformer`、`captureID` の世代照合、カメラとの排他、切断時の停止が既存と同じ不変条件で動作する。
- ピッカーのキャンセル、ユーザーによるシステム UI からの停止、`missingBackgroundMode` が呼び出し元へエラーとして通知される。
- 実機で、アプリをバックグラウンドにしても全画面共有が継続する (`UIBackgroundModes` の `screen-capture` を設定した場合)。
- モックやスタブを使わず、フレーム状態のフィルタリング、向き変換、停止・再開始の世代管理をイベント列で検証する単体テストが追加されている。
- `make build` と既存テストが Xcode 27 環境で成功する。
- 公開 API の追加に合わせて API baseline を再生成し、`make api-check-fresh` が成功する。
- `CHANGES.md` に iOS 27 以降の SCK 対応を追記する。
- ドキュメントに iOS 27 以降の要件、`UIBackgroundModes`、システム音声非対応、既存 API との使い分けが書かれている。

## 関連 issue

- `0061`: App Extension 対応。SCK は Broadcast Upload Extension を不要にするが、Extension 対応そのものは別スコープ。
- `0137`: ReplayKit の start 失敗時に録画が残る問題。SCK 経路は同じ失敗を残さないよう、開始失敗時の停止を完了条件に含める。
- `0097` / `0104` / `0186`: フレームの世代管理、所有境界、ReplayKit callback の隔離。SCK バックエンドはこれらの不変条件を引き継ぐ。

## 解決方法
