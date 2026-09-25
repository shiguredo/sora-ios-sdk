# DummyAudioDevice の共有状態競合を修正する

- Created: 2026-08-27
- Completed:
- Priority: Medium
- Branch: feature/fix-dummy-audio-device-state-races
- Polished: 2026-09-25

## 目的

E2E 用 `DummyAudioDevice` の ADM callback、録音 timer queue、AudioUnit 操作に分散した可変状態を同期し、データ競合と teardown 中の callback 実行を防ぐ。

Thread Sanitizer を有効にした concurrency test の前提として、test helper 自身の race を解消する。

## 現状

`Sora/DummyAudioDevice.swift` の `DummyAudioDevice` は `stateLock` を持ち、`delegate`、`_isRecording`、`isHardMuted` の一部を保護している。

一方、次の状態は同じ同期方針に含まれていない。

- `_isInitialized`
- `_isPlayoutInitialized`
- `_isPlaying`
- `_isRecordingInitialized`
- `audioUnit`
- `recordingTimer`
- `playoutTimer`
- `isHardMuted` の public getter

`startRecording()` / `stopRecording()`、`startPlayout()` / `stopPlayout()`、`terminateDevice()`、property getter、recording / playout timer の callback は別 executor から到達し得る。timer の event handler は `recordingQueue` / `playoutQueue` 上で発火し、実処理は `delegate.dispatchAsync` で ADM スレッドへ移してから実行される。`pcmGenerator` も非 `@Sendable` closure のまま、ADM スレッド（単体テストの `fillPCMData` 直接呼び出しではテストスレッド）から実行される。

`pcmGenerator` に波形生成器を渡している箇所は `SoraTests/SendonlyE2ETests.swift` / `SoraTests/StereoAudioOutputE2ETests.swift` / `SoraTests/DummyStereoAudioLoopbackTests.swift` / `SoraTests/DummyAudioDeviceTests.swift` にあり、`SineWaveGenerator` / `StereoSineWaveGenerator` (どちらも `SoraTests/DummyAudioDeviceTests.swift` の可変状態を持つ非 `Sendable` class) をメソッド参照 (`generator.generate`) または closure で capture している。`pcmGenerator` を `@Sendable` にすると、`Sendable` でない生成器の capture が concurrency 診断 (error) になる。

## 再現手順

1. 実 `RTCPeerConnectionFactory` に `DummyAudioDevice` を渡して接続する。
2. recording / playout の start と stop、hard mute、disconnect を複数 Task から交差させる。
3. Thread Sanitizer を有効にして反復する。
4. recording timer 発火中に `terminateDevice()` を実行する。
5. state property の読み取りと teardown を競合させる。

## 設計方針

- ADM lifecycle state を 1 つの synchronized storage または専用 serial executor で所有する。
- state property の getter と setter を同じ同期方針へ統一する。
- 録音・再生の両タイマー（`recordingTimer` / `playoutTimer`）の生成、交換、cancel と generation を各 owner（recording / playout owner）上で順序付ける。
- timer callback は generation と running state を snapshot し、停止後の callback を破棄する。
- `AUAudioUnit` の操作は AudioUnit の thread contract に従う 1 つの owner へ限定する。
- `pcmGenerator` は `@Sendable` とし、利用者 capture が必要な場合は thread-safe な value / storage だけを許可する。既存の `SineWaveGenerator` / `StereoSineWaveGenerator`（いずれも `SoraTests/DummyAudioDeviceTests.swift` に定義、可変 `phase` / `time` を持つ非 `Sendable` class）は本 issue で Sendable 化（value 型化または lock / executor 化）し、`pcmGenerator` として capture している `testSendonlyDummyAudio`（`SoraTests/SendonlyE2ETests.swift`）、`testMonoDummyHardMuteStopsAndRestartsOutboundAudio` と `verifyStereoPair`（`SoraTests/StereoAudioOutputE2ETests.swift`）、`testStereoPCMThroughRealPeerConnections`（`SoraTests/DummyStereoAudioLoopbackTests.swift`）、`testStereoProbeRejectsSilenceSwappedAndMixedChannels`（`SoraTests/DummyAudioDeviceTests.swift`）の capture を成立させる。value 型化を採る場合、mutating メソッド参照は `let` から渡せないため該当 capture 箇所の渡し方も書き換える必要があり、`@Sendable` な closure は可変な `var` を capture して更新できないため value 型化だけでは capture を成立させられない。生成器の状態は synchronized な参照型 / storage に置く。変更対象は `Sora/DummyAudioDevice.swift` と、`SoraTests/DummyAudioDeviceTests.swift` / `SoraTests/SendonlyE2ETests.swift` / `SoraTests/StereoAudioOutputE2ETests.swift` / `SoraTests/DummyStereoAudioLoopbackTests.swift` である。
- delegate、generator、AudioUnit callback は内部 lock を保持したまま呼ばない。
- `@unchecked Sendable` を class 全体へ追加して診断を抑止しない。
- Thread Sanitizer の実行環境は `0119`（concurrency runtime stress CI）が提供する。本 issue を先に実施し、`0119` の TS 実行が `DummyAudioDevice` の race によるノイズを出さない前提を整える。

## 変更対象

- `Sora/DummyAudioDevice.swift`: ADM lifecycle state を 1 つの synchronized storage / owner へ統一、`recordingTimer` の generation 管理、`pcmGenerator` の `@Sendable` 化
- `SoraTests/DummyAudioDeviceTests.swift`: `SineWaveGenerator` / `StereoSineWaveGenerator` の Sendable 化 (value 型化または lock / executor 化)、生成器を直接呼ぶ箇所と `StereoSineWaveGenerator` の capture (`pcmGenerator: generator.generate`) の追随
- `SoraTests/SendonlyE2ETests.swift`: `SineWaveGenerator` の capture の追随
- `SoraTests/StereoAudioOutputE2ETests.swift`: `StereoSineWaveGenerator` と `SineWaveGenerator` の capture (`pcmGenerator: generator.generate`) の追随
- `SoraTests/DummyStereoAudioLoopbackTests.swift`: `StereoSineWaveGenerator` の capture (`pcmGenerator: source.generate`) の追随
- `CHANGES.md`: `## develop` の `### misc` に、test 側の診断を解消する `[FIX]` を追記する (公開 API と利用者の挙動の変更がないことを補足する)

## テスト方針

モックやスタブは使用しない。

- 実 `DummyAudioDevice` と実 WebRTC ADM callback を利用する。`RTCAudioDevice` のプロトコルメソッドは ADM スレッドから呼ばれるため、race の実行元は ADM スレッド（lifecycle）、`recordingQueue` / `playoutQueue`（timer callback）、disconnect の呼び出し側スレッド（`terminateDevice` の一部）の交差である。この executor 群の交差を start / stop / terminate / hard mute の反復で作り、callback と state の順序を記録する。
- terminate 後に PCM delivery と state 更新が発生しないことは、terminate 完了後に recording timer の発火が起き得ないことを `recordingQueue` 上での確認と、state getter が終端状態を返すことで判定する。
- Thread Sanitizer を有効にした実行（`0119` が提供する TS 環境または同等の実行）で race report が 0 件であることを確認する。
- test には、lock 外で callback を呼ぶ理由と generation の境界を日本語コメントで記載する。
- `pcmGenerator` の `@Sendable` 化後に `SoraTests` を build し、`SineWaveGenerator` / `StereoSineWaveGenerator` の capture に concurrency 診断が出ないことを確認する。判定は実ビルド (`xcodebuild build-for-testing`) で行う (swiftc の単発の型検査は explicit module build と診断が一致せず、region isolation の error を見落とす)。

## 完了条件

- `DummyAudioDevice` の全 mutable state が同じ ownership 方針で管理されていること。
- property getter と lifecycle method の並行実行でデータ競合がないこと。
- terminate 後の timer / AudioUnit callback が state と delegate を利用しないこと。
- `pcmGenerator` の executor と Sendable 契約が明示されていること。
- `SineWaveGenerator` / `StereoSineWaveGenerator` が `Sendable` になっており、`pcmGenerator` の `@Sendable` 化後も `SoraTests/SendonlyE2ETests.swift` / `SoraTests/StereoAudioOutputE2ETests.swift` / `SoraTests/DummyStereoAudioLoopbackTests.swift` / `SoraTests/DummyAudioDeviceTests.swift` の capture に concurrency 診断が出ないこと。
- callback を state lock の外で呼んでいること。
- `CHANGES.md` の `## develop` の `### misc` に、test 側の診断の解消が追記されていること。
- `0119` の Thread Sanitizer 実行環境（または同等の TS を有効にした実行）で race report が 0 件であり、既存 E2E test が成功すること。

## 解決方法
