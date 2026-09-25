# DummyAudioDevice の共有状態競合を修正する

- Created: 2026-08-27
- Completed: 2026-09-25
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
- `isHardMuted` の getter

`startRecording()` / `stopRecording()`、`startPlayout()` / `stopPlayout()`、`terminateDevice()`、property getter、recording / playout timer の callback は別 executor から到達し得る。timer の event handler は `recordingQueue` / `playoutQueue` 上で発火し、実処理は `delegate.dispatchAsync` で ADM スレッドへ移してから実行される。`pcmGenerator` も非 `@Sendable` closure のまま、ADM スレッド（単体テストの `fillPCMData` 直接呼び出しではテストスレッド）から実行される。

`pcmGenerator` に波形生成器を渡している箇所は `SoraTests/SendonlyE2ETests.swift` / `SoraTests/StereoAudioOutputE2ETests.swift` / `SoraTests/DummyStereoAudioLoopbackTests.swift` / `SoraTests/DummyAudioDeviceTests.swift` にあり、`SineWaveGenerator` / `StereoSineWaveGenerator` (どちらも `SoraTests/DummyAudioDeviceTests.swift` の可変状態を持つ非 `Sendable` class) をメソッド参照 (`generator.generate`) または closure で capture している。`pcmGenerator` を `@Sendable` にすると、`Sendable` でない生成器の capture が concurrency 診断 (error) になる。

## 再現手順

以下は手動または Thread Sanitizer 有効時の反復実行で再現させる手順である。実装したテストとの対応も併記する。

1. 実 `RTCPeerConnectionFactory` に `DummyAudioDevice` を渡して接続する。
2. recording / playout の start と stop、hard mute、disconnect を複数 Task から交差させる (`testMonoDummyHardMuteStopsAndRestartsOutboundAudio` が hard mute を、切断経路のテストが disconnect を担当する)。
3. Thread Sanitizer を有効にして反復する。
4. recording timer 発火中に `terminateDevice()` を実行する (`testTerminateWhileConnectedStopsRecordingAndPlayout`)。
5. state property の読み取りと teardown を競合させる。

## 設計方針

- ADM lifecycle state を 1 つの lock 付き storage で所有する (timer / delegate / AudioUnit を含む)。
- state property の getter と setter を同じ同期方針へ統一する。
- 録音・再生の両タイマーの生成、交換、cancel と generation を、timer と世代を対にして持つ値型 (`TimerSlot`) へまとめ、単一の lock が保護する state の中だけで書き換える。
- 開始処理のうち timer / AudioUnit / state フラグを差し込むもの (startRecording / startPlayout / initializePlayout / initializeRecording) は、準備 (delegate や間隔の取得) と state への差し込みが別の lock 区間になるため、ライフサイクルの世代を準備の前後で確認し、`terminateDevice` をまたいだ差し込みを行わない。`initialize(with:)` は新しいライフサイクルを開始するため、`delegate` と `isInitialized` を同じ lock 区間で更新する。
- `terminateDevice` の後始末は、timer の撤去・ライフサイクル世代の更新・`delegate` の解放を同じ lock 区間で行う。
- timer callback は generation と running state を snapshot し、停止後の callback を破棄する。
- `AUAudioUnit` の操作は AudioUnit の thread contract に従う 1 つの owner へ限定する。
- `pcmGenerator` は `@Sendable` とし、利用者 capture が必要な場合は thread-safe な参照型 / storage だけを許可する。既存の `SineWaveGenerator` / `StereoSineWaveGenerator`（いずれも `SoraTests/DummyAudioDeviceTests.swift` に定義、可変 `phase` / `time` を持つ非 `Sendable` class）は本 issue で lock 付き `@unchecked Sendable` とし、`pcmGenerator` として capture している `testSendonlyDummyAudio`（`SoraTests/SendonlyE2ETests.swift`）、`testMonoDummyHardMuteStopsAndRestartsOutboundAudio` と `verifyStereoPair`（`SoraTests/StereoAudioOutputE2ETests.swift`）、`testStereoPCMThroughRealPeerConnections`（`SoraTests/DummyStereoAudioLoopbackTests.swift`）、`testStereoProbeRejectsSilenceSwappedAndMixedChannels`（`SoraTests/DummyAudioDeviceTests.swift`）の capture を成立させる。value 型化は `@Sendable` な closure が可変な `var` を capture して更新できないため採らない。
- delegate、generator、AudioUnit callback は内部 lock を保持したまま呼ばない。
- `@unchecked Sendable` を `DummyAudioDevice` 本体へ付けて診断を抑止しない (テストの生成器は上記のとおり可変状態を lock で保護したうえで付与する)。
- Thread Sanitizer の実行環境は `0119`（concurrency runtime stress CI）が提供する。本 issue を先に実施し、`0119` の TS 実行が `DummyAudioDevice` の race によるノイズを出さない前提を整える。

## 変更対象

- `Sora/DummyAudioDevice.swift`: ADM lifecycle state を 1 つの lock へ統一、`TimerSlot` による timer の世代管理、停止と開始の交差を検出するライフサイクル世代、`pcmGenerator` の `@Sendable` 化
- `SoraTests/DummyAudioDeviceTests.swift`: `SineWaveGenerator` / `StereoSineWaveGenerator` の Sendable 化 (可変状態を lock で保護した `@unchecked Sendable` 準拠)、`pcmGenerator` を `@Sendable` にしたことに伴う capture の追随 (生成器のメソッド参照による capture は無変更だが、可変 `var` を capture していた箇所は lock 付きの箱へ置き換えた)、生成器を並行に呼んでも位相が失われないことと `terminateDevice` が初期のハードミュート状態へ戻すことの検証
- `SoraTests/DummyStereoAudioLoopbackTests.swift`: 実 ADM を接続したまま切断経路から `terminateDevice` を呼ぶ lifecycle の検証テストの追加 (停止の直前まで録音・再生が動いていることの positive control と、停止後に注入・再生が再開せず state が終端へ戻ることの検証)
- `SoraTests/SendonlyE2ETests.swift`: 送信専用接続の device が切断で終端状態へ戻ることの検証を追加 (`SoraTests/StereoAudioOutputE2ETests.swift` は無変更)
- `CHANGES.md`: `## develop` の `### misc` に、`DummyAudioDevice` の共有状態競合の修正を追記する

## テスト方針

モックやスタブは使用しない。

- 実 `DummyAudioDevice` と実 WebRTC ADM callback を利用する。`RTCAudioDevice` のプロトコルメソッドは ADM スレッドからのみ呼ぶ契約 (RTCAudioDevice.h) のため、テストは別スレッドから start / stop を呼ばず、接続確立時に ADM が開始した録音・再生を維持したまま、切断経路 (PeerChannel) と同じくテストスレッドから `terminateDevice` を呼ぶ。PCM の注入と再生は pcmGenerator / playoutHandler の呼び出し回数で観測する。
- terminate 後に PCM delivery と state 更新が発生しないことは、停止の直前まで注入と再生が継続していること (positive control) を確認した上で、停止後に generator / playoutHandler の呼び出し回数が増えず、state getter が終端状態を返すことで判定する (`testTerminateWhileConnectedStopsRecordingAndPlayout`)。
- 開始処理の準備中に停止を差し込む交差は、ADM スレッド契約の下ではテストから強制できない (開始処理も停止の後始末も同じ ADM スレッドに直列化される)。この交差は code 側のライフサイクル世代で防ぎ、テストは停止後の不変条件を検証する。世代不一致で差し込みを拒否する分岐と、AudioUnit の起動後に停止を検出して巻き戻す分岐は契約違反の呼び出しに対する防御であり、契約が守られる限り実行されないためテストでは検証しない (検証するには production にテスト専用のフックが必要になる)。
- AudioUnit (RemoteIO) 経路は、ADM が `initializePlayout` を呼ぶのが受信ストリームを持つ接続に限られるため (送信専用接続では呼ばれない)、実行時検証には送信側から音声を送る受信ありの接続と、受信側に `playoutHandler` を渡さない構成が必要になる。この構成は CI の Simulator では実行できない。`initializePlayout` → `startPlayout` → `AUAudioUnit.startHardware()` → `AURemoteIO::Initialize()` が音声サーバーへの RPC タイムアウトで `abort` し、テストプロセスごと落ちるためである (ローカルの実機に近い環境では起動できるが、CI で再現しないことを保証できない)。実行時検証は実機での確認に委ね、テストでは AudioUnit を起動しない。ローカルの lifecycle 検証は `playoutHandler` 経路で行う。
- 生成器の lock は、`DispatchQueue.concurrentPerform` で同一生成器を並行に呼び、位相が総フレーム数ぶん前進することで検証する (並列度は保証されないため、lock を外した場合の最終的な検出は Thread Sanitizer に委ねる)。
- Thread Sanitizer を有効にした実行（`0119` が提供する TS 環境または同等の実行）で race report が 0 件であることを確認する。実行は build を含む `xcodebuild test -enableThreadSanitizer YES` で行う (`test-without-building` では interceptor が働かない)。race は確率的にしか現れないため対象を反復実行し、検出器が動作することは未修正の既知 race を同じ方法で検出できることで確認する。
- test には、lock 外で callback を呼ぶ理由を日本語コメントで記載する (generation の境界は `TimerSlot` と `deliverPCMData` 側のコメントに記載する)。
- `pcmGenerator` の `@Sendable` 化後に `SoraTests` を build し、`SineWaveGenerator` / `StereoSineWaveGenerator` の capture に concurrency 診断が出ないことを確認する。判定は実ビルド (`xcodebuild build-for-testing`) で行う (swiftc の単発の型検査は explicit module build と診断が一致せず、region isolation の error を見落とす)。

## 完了条件

- `DummyAudioDevice` の全 mutable state が同じ ownership 方針で管理されていること。
- property getter と lifecycle method の並行実行でデータ競合がないこと。
- terminate 後に state の全フラグが終端へ戻り、timer callback が state と delegate を利用しないこと。AudioUnit 経路 (`initializePlayout` / `startPlayout` の AU 分岐と AudioUnit の停止) の実行時検証は受信あり接続が必要で、CI の Simulator では `AURemoteIO` の初期化が RPC タイムアウトで `abort` するため、実機での確認に委ねる。
- `pcmGenerator` の `@Sendable` 契約と、生成器側が排他すべき範囲が明示されていること。
- `SineWaveGenerator` / `StereoSineWaveGenerator` が `Sendable` になっており、`pcmGenerator` の `@Sendable` 化後も `SoraTests/SendonlyE2ETests.swift` / `SoraTests/StereoAudioOutputE2ETests.swift` / `SoraTests/DummyStereoAudioLoopbackTests.swift` / `SoraTests/DummyAudioDeviceTests.swift` の capture に concurrency 診断が出ないこと。
- callback を state lock の外で呼んでいること。
- `CHANGES.md` の `## develop` の `### misc` に、`DummyAudioDevice` の共有状態競合の修正が追記されていること。
- `0119` の Thread Sanitizer 実行環境（または同等の TS を有効にした実行）で race report が 0 件であり、既存 E2E test が成功すること。

## 解決方法

`Sora/DummyAudioDevice.swift` の `DummyAudioDevice` が持つ可変状態を 1 つの lock 付き `State` へ統一し、録音・再生の timer を `TimerSlot` (timer と callback を識別する世代の組) で管理するようにした。

- `terminateDevice` の後始末 (timer の撤去・ライフサイクル世代の更新・`delegate` の解放・AudioUnit の破棄) を同じ lock 区間で行い、停止と開始が交差しても停止後に timer や AudioUnit が残らないようにした。
- 開始処理 (startRecording / startPlayout / initializePlayout / initializeRecording) は、準備の前後でライフサイクルの世代が変わっていないことを確認してから state を差し込む。世代が変わっていた場合は差し込まずに false を返す。
- 未起動の AudioUnit へ `stopHardware()` を呼ばないよう `isHardwareRunning` で停止を判定する。`terminateDevice` では初期のハードミュート状態 (`initialHardMuted`) へ戻す (`Configuration.initialMicrophoneEnabled` は接続時点の状態を定めるため、接続をまたいで `setAudioHardMute` の状態を持ち越さない)。
- `pcmGenerator` を `@Sendable` にし、テストの波形生成器 (`SineWaveGenerator` / `StereoSineWaveGenerator`) の可変状態を lock で保護した。
- テストは実 ADM 接続での lifecycle 検証へ作り直した (停止の直前まで注入と再生が継続していることの positive control と、停止後に注入・再生が再開せず state が終端へ戻ることの検証)。あわせて生成器の並行利用と、ハードミュートの復元を検証するテストを追加した。

検証は `make fmt-lint`、`xcodebuild build-for-testing` (Swift 6、error 0)、ローカルの全 378 tests (30 skipped、0 failures)、Thread Sanitizer を有効にした実行 (`xcodebuild test -enableThreadSanitizer YES`、対象 2 suite を 3 回反復、race report 0 件) で行った。Thread Sanitizer は `0119` の CI job が未実装のためローカルで実行している。検出器が動作することは、未修正の既知の race (`0151` の `PeerChannel.onConnect`) を `PeerChannelConnectCompletionTests` の 20 回反復で検出できることで確認した。AudioUnit 経路の実行時検証も試みたが、CI の Simulator では受信あり接続の `initializePlayout` から `AURemoteIO::Initialize()` が音声サーバーの RPC タイムアウトで `abort` し、テストプロセスごと落ちるためテストを追加しない (実行時検証は実機に委ねる)。CI (Build / Consumer Test / E2E Test) は本修正をコミットした後に実行して確認する。

### 2026-09-25 実機での AudioUnit 経路の検証

CI の Simulator では実行できない AudioUnit (RemoteIO) 経路を実機で確認し、`initializePlayout` / `startPlayout` と `terminateDevice` の AudioUnit 停止が動作することを確認した。

- 端末: iPhone 14 (iPhone14,7)、iOS 26.6.1。Xcode 26.6、libwebrtc は Shiguredo-build M154 (154.8037.1.2 c2b761b)、Sora iOS SDK 2026.3.0 + 本修正
- 方法: quickstart の SDK 依存を一時的にローカルの本リポジトリへ切り替え、`Configuration.audioDevice` に `playoutHandler` を渡さない `DummyAudioDevice` を注入した。送信 PCM は 440 Hz の正弦波とし、device の `isInitialized` / `isPlayoutInitialized` / `isPlaying` / `isRecordingInitialized` / `isRecording` を 1 秒ごとにログへ出した
- 注入のために `Configuration.audioDevice` と `DummyAudioDevice` を public にする確認用のコードを一時的に追加し、検証後に削除した (テスト専用フックを production へ残さないため、コミットしていない)
- 接続: 同じチャンネルに他の接続 (recvonly / sendonly / sendrecv) が存在する状態で接続した。受信ストリームが追加されないと ADM は `initializePlayout` を呼ばないため、単独接続ではこの経路を通らない
- 結果:
  - 22:02:12 (接続直後): `initialized=true playoutInitialized=false playing=false recordingInitialized=true recording=true` (録音経路のみ動作)
  - 22:02:32 (受信ストリームの追加時): libwebrtc が `InitPlayout: Did initialize playout` / `StartPlayout: Did start playout` / `Size of playout buffer: 960` を記録し、同時に `playoutInitialized=true playing=true` になった
  - 22:03:23 の切断 (`reason => user`) で `StopPlayout: Did stop playout` と `StopRecording: Did stop recording`、22:03:24 に全項目 false へ戻った
  - 実機のスピーカーから受信した 440 Hz が聞こえることを確認した (AudioUnit の出力が実際に鳴っていることの確認)
  - クラッシュと `AURemoteIO` の初期化失敗は発生しなかった (CI の Simulator で起きた abort は実機では再現しない)
- 観察: カスタム音声デバイスでは ADM の stereo 設定が失敗として記録された (`adm_helpers.cc:57` / `:77` の "Failed to set stereo playout mode." / "Failed to set stereo recording mode.")。libwebrtc のログレベルを info にしたアプリでのみ見える記録で、AudioUnit 経路の初期化・起動・停止は成功した。本修正はこの設定を変更していない
- 未検証: 開始の途中で停止した場合の AudioUnit の巻き戻し分岐 (ADM スレッド契約の下で交差を強制できない)、割り込みと出力経路の変更
