# SystemBootTime に分類される Required Reason API の利用をなくす

- Created: 2026-11-04
- Completed: {YYYY-MM-DD}
- Branch: feature/remove-system-boot-time-api
- Polished: 2026-11-04
- Priority: Medium

## 目的

Apple は Required Reason API を利用するアプリと SDK に、その利用理由をプライバシーマニフェストで申告することを求めている。Sora はプライバシーマニフェストを同梱していないが、Sora ターゲットは `NSPrivacyAccessedAPICategorySystemBootTime` に分類される API を利用している。Sora ターゲットの Swift ソースから Required Reason API の利用をなくし、マニフェストを同梱しなくても要件を満たす状態にする。あわせて、テスト専用の型 `DummyAudioDevice` が SDK ターゲットに同梱されている状態を解消する。

本 issue ではマニフェストを追加せず、API 利用をなくす方針を採る。

## 現状

- Sora はプライバシーマニフェストを同梱していない。`Package.swift` の `Sora` ターゲットの `resources` は `VideoView.xib` のみ
- Sora ターゲットは Required Reason API の SystemBootTime を 2 種類利用している
  - `Sora/ScreenCapture.swift` の `ScreenCaptureController` の `shouldSendVideoFrameWithUptime()` と `markVideoFrameSent(presentationTimestamp:)` が `ProcessInfo.processInfo.systemUptime` でフレーム間隔を測っている。このフォールバックは 2026-02-18 の変更 (`90147559`) で追加された
  - `Sora/DummyAudioDevice.swift` の `consumePlayoutData(generation:)` と `deliverPCMData(generation:)` が `AudioTimeStamp.mHostTime` に `mach_absolute_time()` を設定している。録音経路は 0068 (`5ed26b6d`)、再生経路はステレオ音声出力対応 (`003bb738`) で追加された
- `DummyAudioDevice` は `Configuration.audioDevice` (internal) 経由でテストから注入する用途だが、`#if DEBUG` などの条件付きコンパイルはなく `Sora` ターゲットに常にコンパイルされる
- Release ビルドの `Sora.o` には、`ScreenCapture` の `systemUptime` が `_objc_msgSend$systemUptime`、`DummyAudioDevice` の `mach_absolute_time()` が `_mach_absolute_time` として参照シンボルに残る
- `Sora/MediaChannel.swift` の `setAudioHardMute` は `nativePeerChannelFactory.audioDevice as? DummyAudioDevice` で具体型を参照し、`DummyAudioDevice.setHardMute(_:)` を呼ぶ。ダミー経路のコメントとエラーメッセージにも具体型名が入っている
- `Sora` ターゲットで Required Reason API を利用する箇所は上記の 4 箇所のみで、他のカテゴリ (UserDefaults / ファイル時刻 / ディスク容量 / キーボード) の利用はない

## 設計方針

- `Sora/ScreenCapture.swift`: `ProcessInfo.processInfo.systemUptime` を `CACurrentMediaTime()` (QuartzCore) に置き換える。`import QuartzCore` を追加し、経過時間の計算方法と PTS 無効時の間引き動作は変えない
  - `lastSentVideoUptime` など uptime を前提にした private 名、`ScreenCaptureController` の class doc の状態リスト、送信直前の記録に関するコメント、`SoraTests/ScreenCaptureFrameGenerationTests.swift` の `testShouldSendVideoFrameFallsBackToUptimeWhenTimestampIsInvalid()` の名前とコメントを実態に合わせる
  - `CACurrentMediaTime()` は秒単位の単調時刻で、現在の Apple の Required Reason API 一覧には含まれていない。経過時間の差分にだけ使うため、`ProcessInfo.processInfo.systemUptime` と基盤時刻が同一であることを前提にしない
  - 本 issue では Required Reason API の一覧が API 名ベースである前提を採り、`CACurrentMediaTime()` への置き換えを採用する。Apple のドキュメント上 `CACurrentMediaTime()` は `mach_absolute_time()` を秒に換算した値であるため、一覧の趣旨に照らした再検討が必要になった場合は、本 issue では実装を進めず pending にしてユーザーに判断を仰ぐ。時間ベースの間引き自体の設計見直しは別 issue とする
- `Sora/DummyAudioDevice.swift`: `SoraTests/DummyAudioDevice.swift` へ移動し、`Sora` ターゲットから除外する。`SoraTests/DummyVideoCapturer.swift` と同じ配置方針とする
  - `Sora/Configuration.swift` に internal なプロトコル (例: `HardMuteSwitchableAudioDevice`) を追加し、`DummyAudioDevice` が準拠する。`Sora/MediaChannel.swift` の `setAudioHardMute` は具体型ではなくプロトコルへキャストして `setHardMute(_:)` を呼ぶ
  - `Sora/MediaChannel.swift` のダミー音声経路のコメントと、到達しない失敗経路のエラーメッセージから具体型名を外す (例: `"hard mute failed for the custom audio device"`)。`DummyAudioDevice.setHardMute(_:)` は常に `true` を返すためこの失敗経路は到達せず、外部から観測できる挙動は変わらない。公開 API も変えない。非対応を表す既存の `"setAudioHardMute is not supported"` は変更しない
  - `Sora/Configuration.swift` と `Sora/PeerChannel.swift` の DummyAudioDevice を名指しするコメントを一般的な表現に直す。`LogType.dummyAudioDevice` は公開 API のため変更しない
  - 移動後の `DummyAudioDevice` は `import WebRTC` と `@testable import Sora` を使う。`SoraTests` は既に WebRTC を import しているため `Package.swift` の依存追加は不要
  - `SoraTests/DummyAudioDeviceTests.swift` に `import WebRTC` を追加し、`DummyAudioDevice` が新しいプロトコルへ準拠することを検証する単体テストを追加する。`MediaChannel` と同じキャストで `setHardMute(_:)` を呼べることも確認する。ダミー経路の `setAudioHardMute` は E2E テストでしか通らず、`SORA_SIGNALING_URL` 未設定の環境ではスキップされるため、準拠の取りこぼしを単体テストで防ぐ
- `.github/workflows/build.yml`: Required Reason API の再導入を検知できるよう、Release ビルド後に `Sora.o` の未定義シンボルを `nm` で検査する step を追加する。既存の「Check WebRTC Non-public API」step と同じ形とし、`_mach_absolute_time` と `_objc_msgSend$systemUptime` が無いことを確認する。`_objc_msgSend$systemUptime` はシェルで変数展開されないようシングルクォートで指定し、`Sora.o` が見つからない場合は step を失敗させる
- `CHANGES.md`: `## develop` に `### misc` を新設し、`[UPDATE]` でテスト専用コードの除去とフレーム間引きの時刻取得 API の変更を追記する
- 0198 (open) はプライバシーマニフェストを同梱する別方針であり、本 issue と排他である。0198 を先に実装すると本 issue の前提 (マニフェスト非同梱) が崩れるため、本 issue を先に実装し、0198 の扱い (closed / pending) は別途判断する
- 公開 API は変更しない

## 変更対象

- `Sora/ScreenCapture.swift`
- `Sora/DummyAudioDevice.swift` (削除、`SoraTests/DummyAudioDevice.swift` へ移動)
- `Sora/MediaChannel.swift`
- `Sora/Configuration.swift`
- `Sora/PeerChannel.swift`
- `SoraTests/DummyAudioDevice.swift` (新規、移動先)
- `SoraTests/DummyAudioDeviceTests.swift`
- `SoraTests/ScreenCaptureFrameGenerationTests.swift`
- `.github/workflows/build.yml`
- `CHANGES.md`

## 完了条件

- `grep -rn "systemUptime\|mach_absolute_time\|[Uu]ptime" Sora/` が 0 件 (コメントを含む)
- `make build` 後の `build/Build/Products/Release-iphoneos/Sora.o` を `nm -u` して `_mach_absolute_time` と `_objc_msgSend$systemUptime` が無い (Xcode 26.6 / iphoneos26.5 が揃わない環境では `XCODE_SDK=iphoneos27.0` を指定する。生成物のパスは変わらない)
- `SoraTests/DummyAudioDeviceTests.swift` に追加したプロトコル準拠の単体テストを含め、シミュレータテストが全件成功する (`.github/workflows/e2e-test.yml` と同じ `xcodebuild build-for-testing -scheme Sora-Package` + `test-without-building` の手順で実行する。iphoneos26.5 が無い環境では `-sdk iphoneos27.0` と、その SDK に対応する Simulator OS を指定する)
- `SoraTests/ScreenCaptureFrameGenerationTests.swift` のテスト名とコメントが実態に合っている (`grep -rn "FallsBackToUptime" SoraTests/` が 0 件。`SoraTests/DummyVideoCapturer.swift` の `systemUptime` はテスト専用ヘルパーのため変更しない)
- `make fmt-lint` と `make lint` が成功する
- 公開 API が変わらないため `make api-check-fresh` が成功する (Xcode 26.6 / iphoneos26.5 が揃わない環境では CI で確認する)
- `make consumer-build SCHEME=ConsumerCore` が成功する (Xcode 26.6 / iphoneos26.5 が揃わない環境では `XCODE_SDK=iphoneos27.0` を指定する)
- `build.yml` の追加 step が `Sora.o` に Required Reason API のシンボルが無いことを検査する
- `CHANGES.md` の `## develop` の `### misc` に追記されている

## 参考

- [Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)
- [Describing use of required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- [NSPrivacyAccessedAPIType](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
- [CACurrentMediaTime()](https://developer.apple.com/documentation/quartzcore/cacurrentmediatime())
- 関連 issue: 0068 (ダミー音声デバイスの追加)
- 関連コミット: `90147559` (PTS 無効時のフォールバック)、`5ed26b6d` (0068 録音経路)、`003bb738` (ステレオ音声出力の再生経路)
- 0198 (open): プライバシーマニフェストを同梱する別方針。本 issue とは排他
- 0070 / 0019 / 0088 (open) は `Sora/DummyAudioDevice.swift` のパスを引用しているため、本 issue で `SoraTests` へ移すと参照が古くなる
- 0192 / 0197 (open) は `Sora/ScreenCapture.swift` を変更対象にしており、0192 と 0197 は `Sora/MediaChannel.swift` も変更対象にしているため、実装順によってはテキスト衝突が起きる
