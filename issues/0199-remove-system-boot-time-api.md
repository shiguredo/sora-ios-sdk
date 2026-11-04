# SystemBootTime に分類される Required Reason API の利用をなくす

- Created: 2026-11-04
- Completed: {YYYY-MM-DD}
- Branch: feature/remove-system-boot-time-api
- Polished: {YYYY-MM-DD}
- Priority: Medium

## 目的

Sora iOS SDK はプライバシーマニフェストで `NSPrivacyAccessedAPICategorySystemBootTime` を理由コード `35F9.1` と `8FFB.1` 付きで申告している。この申告を不要にし、SDK が Required Reason API に依存しない状態にする。あわせて、テスト専用コードが SDK ターゲットに同梱されている状態を解消する。

申告が不要になれば、SDK の同梱物からプライバシーマニフェスト自体を削除でき、SDK 側で申告内容を維持するコストをなくせる。

## 現状

- `Sora/PrivacyInfo.xcprivacy` は `NSPrivacyAccessedAPICategorySystemBootTime` に `35F9.1` と `8FFB.1` を宣言している。`Package.swift` の `Sora` ターゲットはこのファイルを `resources` に含め、`SoraTests/PrivacyManifestTests.swift` が同梱と内容を検証している
- `35F9.1` の根拠は `Sora/ScreenCapture.swift` の `ScreenCaptureController` にある。`shouldSendVideoFrameWithUptime()` と `markVideoFrameSent(presentationTimestamp:)` が `ProcessInfo.processInfo.systemUptime` を使い、PTS が無効なフレームの間引き間隔を測っている。このフォールバックは 2026-02-18 の変更 (`90147559`) で追加された
- `8FFB.1` の根拠は `Sora/DummyAudioDevice.swift` にある。`consumePlayoutData(generation:)` と `deliverPCMData(generation:)` が `AudioTimeStamp.mHostTime` に `mach_absolute_time()` を設定している。このクラスは `Configuration.audioDevice` (internal) 経由でテストから注入する用途だが、`#if DEBUG` などの条件付きコンパイルはなく `Sora` ターゲットに常にコンパイルされ、Release ビルドの `Sora.o` にも `_mach_absolute_time` の参照シンボルが残る。録音経路は 0068 (`5ed26b6d`)、再生経路はステレオ音声出力対応 (`003bb738`) で追加された
- `Sora/MediaChannel.swift` の `setAudioHardMute` は `nativePeerChannelFactory.audioDevice as? DummyAudioDevice` で具体型を参照し、`DummyAudioDevice.setHardMute(_:)` を呼ぶ
- `Sora` ターゲットで Required Reason API を利用する箇所は上記の 4 箇所のみで、他のカテゴリの利用はない
- 0198 では `WebRTC.xcframework` のマニフェストと形状を揃えて `NSPrivacyCollectedDataTypes` を空配列、`NSPrivacyTracking` を `false` としており、SDK が収集するデータの申告は対象外のまま

## 設計方針

- `Sora/ScreenCapture.swift`: `ProcessInfo.processInfo.systemUptime` を `CACurrentMediaTime()` (QuartzCore) に置き換える。秒単位の単調時刻で、現在の Apple の Required Reason API 一覧には含まれていない。`import QuartzCore` を追加し、経過時間の計算方法と PTS 無効時の間引き動作は変えない
  - `lastSentVideoUptime` など uptime を前提にした private 名、型 doc の申告に関する記述、`SoraTests/ScreenCaptureFrameGenerationTests.swift` の `testShouldSendVideoFrameFallsBackToUptimeWhenTimestampIsInvalid()` の名前とコメントを実態に合わせる
  - 同じ基盤時刻を使う API への置き換えであり、時間計測自体は続ける。Apple が一覧を更新して `CACurrentMediaTime()` を追加した場合は理由コードを再検討する
- `Sora/DummyAudioDevice.swift`: `SoraTests/DummyAudioDevice.swift` へ移動し、`Sora` ターゲットから除外する。`SoraTests/DummyVideoCapturer.swift` と同じ配置方針とする
  - `Sora/Configuration.swift` に internal なプロトコル (例: `HardMuteSwitchableAudioDevice`) を追加し、`DummyAudioDevice` が準拠する。`Sora/MediaChannel.swift` の `setAudioHardMute` は具体型ではなくプロトコルへキャストして `setHardMute(_:)` を呼ぶ
  - 移動後の `DummyAudioDevice` は `import WebRTC` と `@testable import Sora` を使う。`SoraTests` は既に WebRTC を import しているため `Package.swift` の依存追加は不要
  - `Sora/Configuration.swift` と `Sora/PeerChannel.swift` の DummyAudioDevice を名指しするコメントを一般的な表現に直す。`LogType.dummyAudioDevice` は公開 API のため変更しない
- `Sora/PrivacyInfo.xcprivacy`: 申告対象がなくなるため削除する。`Package.swift` の `Sora` ターゲットの `resources` を `[.process("VideoView.xib")]` に戻す
- `SoraTests/PrivacyManifestTests.swift`: マニフェストを削除するため、テストも削除する。Required Reason API の利用がなくなり、0198 の整理のとおり収集データの申告は空配列、トラッキングも行っていないため、現時点の方針では Apple の "Privacy manifest files" が示す同梱条件に該当しない。将来、データ収集の申告や Required Reason API の利用が必要になった時点で再追加する
- 公開 API と SDK の挙動は変更しない。`CHANGES.md` の `## develop` の `### misc` に `[UPDATE]` を追加する

## 変更対象

- `Sora/ScreenCapture.swift`
- `Sora/DummyAudioDevice.swift` (削除、`SoraTests/DummyAudioDevice.swift` へ移動)
- `Sora/MediaChannel.swift`
- `Sora/Configuration.swift`
- `Sora/PeerChannel.swift`
- `Sora/PrivacyInfo.xcprivacy` (削除)
- `SoraTests/DummyAudioDevice.swift` (新規、移動元)
- `SoraTests/PrivacyManifestTests.swift` (削除)
- `SoraTests/ScreenCaptureFrameGenerationTests.swift`
- `Package.swift`
- `CHANGES.md`

## 完了条件

- `Sora` ターゲットのソースに `ProcessInfo.systemUptime` と `mach_absolute_time()` の利用が無い
- Release ビルドの `Sora.o` に `_mach_absolute_time` の参照シンボルが無い
- `Sora` のソースツリーと `Sora_Sora.bundle` に `PrivacyInfo.xcprivacy` が含まれない
- シミュレータテストが全件成功する
- `make fmt-lint` と `make lint` が成功する
- 公開 API が変わらないため `make api-check-fresh` が成功する
- `make consumer-build SCHEME=ConsumerCore` が成功し、`Sora_Sora.bundle` に `PrivacyInfo.xcprivacy` が含まれない
- `CHANGES.md` の `## develop` の `### misc` に追記されている

## 参考

- [Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)
- [Describing use of required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- [NSPrivacyAccessedAPIType](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
- [CACurrentMediaTime()](https://developer.apple.com/documentation/quartzcore/cacurrentmediatime())
- [TN3181: Debugging an invalid privacy manifest](https://developer.apple.com/documentation/technotes/tn3181-debugging-an-invalid-privacy-manifest)
- 関連 issue: 0198 (プライバシーマニフェストの同梱)、0068 (ダミー音声デバイスの追加)
- 関連コミット: `90147559` (PTS 無効時のフォールバック)、`5ed26b6d` (0068 録音経路)、`003bb738` (ステレオ音声出力の再生経路)
