# ダミー音声デバイス (RTCAudioDevice 実装) を追加する

- Priority: Medium
- Created: 2026-06-08
- Completed: 2026-08-07
- Model: deepseek-v4-pro
- Branch: feature/add-dummy-audio-source
- Polished: 2026-08-07

## 目的

Sora iOS SDK を利用したアプリケーションのテストやデモにおいて、物理的なマイクを使用せずにダミーの音声データを生成して送信できる仕組みを提供する。`RTCAudioDevice` プロトコルは送受信一体であり、カスタムデバイスを `RTCPeerConnectionFactory` に渡すと遠隔音声の再生も自前で行う必要があるため、`AUAudioUnit`（RemoteIO）経由の再生実装も本 issue のスコープに含む。

## 調査結果（解決済み）

実装にあたり調査した項目の結論:

- **実装言語: Swift（`.mm` 不要）**: `RTCAudioDevice.h` には C++ 依存が一切なく、全型が Foundation / CoreAudio / GCD の C 型で構成されている。Sora プロジェクト内でも `PeerChannel: RTCPeerConnectionDelegate` など 7 箇所で ObjC プロトコルへの Swift 準拠の前例がある。`.mm` の SPM ビルド設定問題を回避し、Swift での実装とする
- **再生: AUAudioUnit を使用**: `AUAudioUnit` の `outputProvider` ブロック経由で `delegate.getPlayoutData` を呼ぶ方式を採用する。`AVAudioEngine` よりコード量が少なく、再生経路のみ必要な本ユースケースに適している。参考実装: [mstyura/RTCAudioDevice](https://github.com/mstyura/RTCAudioDevice) の `AUAudioUnitRTCAudioDevice.swift`
- **録音: DispatchSourceTimer を使用**: マイクを使わずに PCM データを生成して注入するため、`DispatchSourceTimer` で定期生成し `delegate.deliverRecordedData` で注入する方式を採用する。`AUAudioUnit` の入力経路（マイク）は使わない
- **AVAudioSession は DummyAudioDevice が設定する**: `RTCAudioDevice.h` に「Implementation is fully responsible for configuring application's AVAudioSession」と明記されている。カスタム `RTCAudioDevice` 経由では libwebrtc の ADM が AVAudioSession を設定しないため、`DummyAudioDevice` 自身が `initialize(with:)` でカテゴリ（`playAndRecord`）を設定し、アクティベートする
- **AudioBufferList のメモリ管理: malloc/free でよい**: フレームあたりのアロケーションは約 1944 bytes（AudioBufferList 24 bytes + データ 1920 bytes）、秒間約 97 KB。iOS デバイスにとって無視できる量であり、事前確保による「解放済みメモリへの誤アクセス」リスクを避けるため、malloc/free のシンプルな方式を採用する。「Premature Optimization is the Root of All Evil」に従い、計測可能な問題が発生しない限り最適化しない
- **2 チャネル録音の制約**: webrtc-build 側の ADM は録音データを取り込む際にチャネル数を乗算せずフレーム数分のサンプルしか読まない（`objc_audio_device.mm:450-452`）。そのため 2 チャネル指定では取り込みが半分になり音声が破損する。本 issue ではチャネル数を 1 固定とする

## 現状

音声入力は `RTCAudioDeviceModule` （WebRTC フレームワークの ObjC クラス）を通じて管理され、物理マイクからの音声データが `RTCAudioTrack` に流される（`Sora/NativePeerChannelFactory.swift:36-68`）。このクラスにはサブクラス化や delegate による音声データ注入の API は存在しない。

## 関連 issue

- `0019-investigate-audio-source-mixing` は `RTCAudioDeviceModule` の差し替えを調査対象としている。本 issue は 0019 とは独立して実装する。`RTCPeerConnectionFactory.initWithEncoderFactory:decoderFactory:audioDevice:` の実在は `RTCPeerConnectionFactory.h` で確認済みである
- `0070-change-migrate-to-webrtc-c-xcframework` は Phase 3-4 で `NativePeerChannelFactory` / `PeerChannel` / `MediaChannel` を書き換える予定であり、本 issue の変更ファイルと重複する。webrtc_c にはカスタム音声デバイス注入（`RTCAudioDevice` 相当）の C API が含まれておらず、移行時はダミー音声機能の実現方法の検討が必要になる（0070 の AudioDeviceModule 節に [Blocker] として追記が必要）。なお 0070 側の本 issue への言及（「`RTCVideoFrame` / `RTCVideoSource.capturer(_:didCapture:)` 直接依存」）は誤りであり、本 issue は `RTCAudioDevice` / `RTCPeerConnectionFactory` / `RTCAudioDeviceModule` に依存する。0070 実装時に修正が必要
- `0078-add-e2e-audio-test` は実機 E2E テスト（`E2ETests` への追加）として実マイク前提の音声送信テストを追加する予定である。ダミー音声 E2E テストは本 issue で実装し、実マイク E2E テストは 0078 が実装する
- `0067-add-dummy-video-source`（closed）のダミー映像と組み合わせて、シミュレーター / CI 環境での完全なメディア通信テストを可能にする

## 設計方針

### 全体方針

- `RTCAudioDevice` プロトコルを実装した `DummyAudioDevice` クラスを **Swift** で作成する（詳細は調査結果参照）
- `DummyAudioDevice` を `RTCPeerConnectionFactory.init(encoderFactory:decoderFactory:audioDevice:)` に直接渡す
- `NativePeerChannelFactory` を修正し、ダミー音声有効時にカスタム `RTCAudioDevice` を使用する
- `Configuration` にダミー音声の設定を追加する

### `RTCAudioDevice` プロトコル実装の責務

以下は `RTCAudioDevice.h` の実際の定義に基づく。`DummyAudioDevice` は全 13 プロパティ + 8 メソッドを実装する必要がある。なお、ObjC の `initializeWithDelegate:` セレクタは Swift では `initialize(with:)` に自動改名されるため、Swift 実装では `initialize(with:)` を使用する:

| プロパティ/メソッド | 戻り値の型 | ダミー実装での動作 |
|---|---|---|
| `deviceInputSampleRate` | `double` | `delegate.preferredInputSampleRate` を返す |
| `inputIOBufferDuration` | `NSTimeInterval` | `delegate.preferredInputIOBufferDuration` を返す |
| `inputNumberOfChannels` | `NSInteger` | 1 を返す |
| `inputLatency` | `NSTimeInterval` | 0 を返す |
| `deviceOutputSampleRate` | `double` | `delegate.preferredOutputSampleRate` を返す |
| `outputIOBufferDuration` | `NSTimeInterval` | `delegate.preferredOutputIOBufferDuration` を返す |
| `outputNumberOfChannels` | `NSInteger` | 1 を返す |
| `outputLatency` | `NSTimeInterval` | 0 を返す |
| `isInitialized` | `BOOL` | `initialize(with:)` 呼び出し後は `true` |
| `isPlayoutInitialized` | `BOOL` | `initializePlayout` 呼び出し後は `true` |
| `isPlaying` | `BOOL` | `startPlayout` 呼び出し後は `true` |
| `isRecordingInitialized` | `BOOL` | `initializeRecording` 呼び出し後は `true` |
| `isRecording` | `BOOL` | `startRecording` 呼び出し後は `true` |
| `initialize(with:)` | `BOOL` | delegate を保持し、AVAudioSession を設定し、`true` を返す |
| `terminateDevice` | `BOOL` | ADM スレッド上で録音タイマー・AUAudioUnit を停止し、delegate を nil にして `true` を返す |
| `initializePlayout` | `BOOL` | AUAudioUnit を生成・設定し `true` を返す。失敗時は `false` |
| `startPlayout` | `BOOL` | `audioUnit?.startHardware()` を呼び `true` を返す |
| `stopPlayout` | `BOOL` | `audioUnit?.stopHardware()` を呼び `true` を返す |
| `initializeRecording` | `BOOL` | `_isRecordingInitialized = true` として `true` を返す |
| `startRecording` | `BOOL` | 既存タイマーをキャンセル後、`DispatchSourceTimer` を同期的に生成・開始し `true` を返す |
| `stopRecording` | `BOOL` | `DispatchSourceTimer` をキャンセルし `true` を返す |

入出力のサンプルレート・IO バッファ期間は `delegate.preferred*` の値を使用することで、libwebrtc 内部での不要なリサンプリングを回避する。チャネル数は 1 固定とする（理由は調査結果を参照）。

### `DummyAudioDevice` Swift 実装（全体構造）

```swift
// Sora/DummyAudioDevice.swift (新規追加)
import AudioToolbox
import AVFoundation
import Foundation
import WebRTC

final class DummyAudioDevice: NSObject, RTCAudioDevice {

  private let config: DummyAudioConfig

  private weak var delegate: RTCAudioDeviceDelegate?

  // 録音用
  private var recordingTimer: DispatchSourceTimer?
  private let recordingQueue = DispatchQueue(
    label: "jp.shiguredo.sora.dummy-audio.recording")

  // 再生用
  private var audioUnit: AUAudioUnit?

  private var _isInitialized = false
  private var _isPlayoutInitialized = false
  private var _isPlaying = false
  private var _isRecordingInitialized = false
  private var _isRecording = false

  // 正弦波の位相 (フレーム境界での波形不連続を防ぐ)
  private var phase: Double = 0

  init(config: DummyAudioConfig) {
    self.config = config
    super.init()
  }

  // 異常経路で terminateDevice が呼ばれずに解放された場合に備える
  deinit {
    recordingTimer?.cancel()
  }

  // MARK: - RTCAudioDevice プロパティ

  var deviceInputSampleRate: Double {
    delegate?.preferredInputSampleRate ?? 48000
  }

  var inputIOBufferDuration: TimeInterval {
    delegate?.preferredInputIOBufferDuration ?? 0.02
  }

  var inputNumberOfChannels: Int { 1 }

  var inputLatency: TimeInterval { 0 }

  var deviceOutputSampleRate: Double {
    delegate?.preferredOutputSampleRate ?? 48000
  }

  var outputIOBufferDuration: TimeInterval {
    delegate?.preferredOutputIOBufferDuration ?? 0.02
  }

  var outputNumberOfChannels: Int { 1 }

  var outputLatency: TimeInterval { 0 }

  var isInitialized: Bool { _isInitialized }
  var isPlayoutInitialized: Bool { _isPlayoutInitialized }
  var isPlaying: Bool { _isPlaying }
  var isRecordingInitialized: Bool { _isRecordingInitialized }
  var isRecording: Bool { _isRecording }
}
```

### 初期化と AVAudioSession の設定

`initialize(with:)` で AVAudioSession を設定する。`playAndRecord` カテゴリはデフォルトで受話口（レシーバー）に出力されるため、`.defaultToSpeaker` オプションを指定する:

```swift
func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
  self.delegate = delegate

  // RTCAudioDevice 実装は AVAudioSession の設定責務を持つ (RTCAudioDevice.h)
  do {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(
      .playAndRecord,
      mode: .default,
      options: [.defaultToSpeaker])
    try session.setActive(true)
  } catch {
    // 失敗時も true を返す。false を返すと ADM の初期化失敗となり、
    // 接続処理がクラッシュする (adm_helpers.cc の RTC_CHECK) ため、警告ログのみで継続する。
    // _isInitialized は true に設定したままにする。false のままだと 2 回目以降の
    // ADM の Init で再初期化が試みられ、録音・再生が不安定になるためである
    Logger.warn(
      type: .dummyAudioDevice,
      message: "failed to configure AVAudioSession: \(error.localizedDescription)")
  }

  _isInitialized = true
  return true
}
```

### 再生（Playout）の実装

`initializePlayout` で AUAudioUnit（RemoteIO）を生成し、出力フォーマットを Int16 に明示設定した上で、`outputProvider` ブロックで `delegate.getPlayoutData` を呼び出す:

```swift
func initializePlayout() -> Bool {
  guard let delegate else { return false }

  let desc = AudioComponentDescription(
    componentType: kAudioUnitType_Output,
    componentSubType: kAudioUnitSubType_RemoteIO,
    componentManufacturer: kAudioUnitManufacturer_Apple,
    componentFlags: 0,
    componentFlagsMask: 0)

  guard let au = try? AUAudioUnit(componentDescription: desc) else {
    Logger.warn(type: .dummyAudioDevice,
      message: "failed to create AUAudioUnit")
    return false
  }
  au.isOutputEnabled = true
  au.isInputEnabled = false  // 録音は別経路（タイマー）のため入力不要
  au.maximumFramesToRender = 1024

  // outputProvider が提供するデータのフォーマットは inputBus 0 のフォーマットに従う。
  // ADM の OnGetPlayoutData は AudioBufferList が Int16 かつ 1〜2 チャネルであることを要求するため、
  // RemoteIO のデフォルト（Float32）ではなく Int16 フォーマットを inputBusses[0] に明示設定する
  let format = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: delegate.preferredOutputSampleRate,
    channels: 1,
    interleaved: true)
  guard let format else { return false }
  do {
    try au.inputBusses[0].setFormat(format)
  } catch {
    Logger.warn(type: .dummyAudioDevice,
      message: "failed to set output format: \(error.localizedDescription)")
    return false
  }

  let getPlayoutData = delegate.getPlayoutData
  au.outputProvider = { (actionFlags, timestamp, frameCount, inputBusNumber, outputData) -> AUAudioUnitStatus in
    return getPlayoutData(actionFlags, timestamp, inputBusNumber, frameCount, outputData)
  }

  do {
    try au.allocateRenderResources()
  } catch {
    Logger.warn(type: .dummyAudioDevice,
      message: "failed to allocate render resources: \(error.localizedDescription)")
    return false
  }

  audioUnit = au
  _isPlayoutInitialized = true
  return true
}

func startPlayout() -> Bool {
  guard let au = audioUnit else { return false }
  do {
    try au.startHardware()
  } catch {
    Logger.warn(type: .dummyAudioDevice,
      message: "failed to start hardware: \(error.localizedDescription)")
    return false
  }
  _isPlaying = true
  return true
}

func stopPlayout() -> Bool {
  audioUnit?.stopHardware()
  _isPlaying = false
  return true
}
```

### 録音（Recording）の実装

`startRecording` で `DispatchSource.makeTimerSource()` を同期的に生成して開始する。`deliverRecordedData` は `recordingQueue` のタイマーハンドラからのみ呼び出す:

```swift
func initializeRecording() -> Bool {
  _isRecordingInitialized = true
  return true
}

func startRecording() -> Bool {
  guard let delegate else { return false }

  // 既存タイマーが残っている場合は先にキャンセルする。
  // Offer SDP 作成のたびに startRecording が呼ばれ得るため、再入は安全でなければならない
  recordingTimer?.cancel()

  _isRecording = true

  let timer = DispatchSource.makeTimerSource(queue: recordingQueue)
  let interval = delegate.preferredInputIOBufferDuration
  let intervalNs = Int(interval * Double(NSEC_PER_SEC))

  // ADM 側が recording フラグを立てる前に届いた最初のフレームが破棄されるため、
  // 1 インターバル分遅らせて開始する
  timer.schedule(deadline: .now() + .nanoseconds(intervalNs), repeating: .nanoseconds(intervalNs))
  timer.setEventHandler { [weak self] in
    self?.deliverPCMData()
  }
  timer.resume()
  recordingTimer = timer
  return true
}

  func stopRecording() -> Bool {
    recordingTimer?.cancel()
    recordingTimer = nil
    _isRecording = false
    return true
  }

  /// ハードミュートを有効化/無効化する
  /// - Parameter mute: `true` でミュート有効化、`false` でミュート無効化
  /// - Returns: 成功した場合は `true`
  func setHardMute(_ mute: Bool) -> Bool {
    let update: () -> Void = { [weak self] in
      self?.isHardMuted = mute
    }
    if let delegate {
      delegate.dispatchSync(update)
    } else {
      update()
    }
    return true
  }
```

### ハードミュート (初期ミュート) の制御

`Configuration.initialMicrophoneEnabled` の契約（`false` のとき「接続時点ではマイク入力は無効」「後から `setAudioHardMute(false)` で有効化」）をダミー音声経路でも守る:

- `DummyAudioDevice` は `isHardMuted` フラグを持ち、`DummyAudioConfig.initialMicrophoneEnabled` が `false` の場合は初期状態でミュートする
- `deliverPCMData` は `isHardMuted == true` の場合、`deliverRecordedData` を呼ばずに録音データを送信しない
- `MediaChannel.setAudioHardMute(_:)` は、`audioDeviceModuleWrapper` が nil（ダミー音声有効）の場合、`DummyAudioDevice.setHardMute(_:)` を呼び出してハードミュートを切り替える

```swift
// DummyAudioDevice.swift 内
// ハードミュート状態。initialMicrophoneEnabled = false の場合は初期状態でミュートする
private(set) var isHardMuted: Bool

init(config: DummyAudioConfig) {
  self.config = config
  self.isHardMuted = !config.initialMicrophoneEnabled
  super.init()
}

// deliverPCMData 内、冒頭に追加
if isHardMuted {
  return
}
```



private func deliverPCMData() {
  guard let delegate, _isRecording else { return }

  let sampleRate = delegate.preferredInputSampleRate
  // ADM 側と同じ四捨五入でフレーム数を算出する (objc_audio_device.mm に合わせる)
  let frameCount = UInt32((sampleRate * delegate.preferredInputIOBufferDuration) + 0.5)
  // サンプルレート・IO バッファ期間が異常値の場合に備える
  guard frameCount > 0 else {
    Logger.warn(type: .dummyAudioDevice, message: "invalid frame count: \(frameCount)")
    return
  }
  let dataSize = Int(frameCount) * MemoryLayout<Int16>.size

  let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
  bufferList.initialize(to: AudioBufferList())
  defer {
    free(bufferList.pointee.mBuffers.mData)
    bufferList.deallocate()
  }
  bufferList.pointee.mNumberBuffers = 1
  bufferList.pointee.mBuffers.mNumberChannels = 1
  bufferList.pointee.mBuffers.mDataByteSize = UInt32(dataSize)
  bufferList.pointee.mBuffers.mData = malloc(dataSize)

  // malloc 失敗時はこのフレームをスキップする
  guard let data = bufferList.pointee.mBuffers.mData else {
    Logger.warn(type: .dummyAudioDevice, message: "failed to allocate PCM data")
    return
  }

  fillPCMData(data: data, frameCount: Int(frameCount), sampleRate: sampleRate)

  // ADM のジッタバッファ制御がタイムスタンプを参照するため、ホスト時刻と有効フラグを設定する
  // (mFlags がないと AudioTimeStampGetNanoseconds が nullopt を返し、時刻が無視される)
  var timestamp = AudioTimeStamp()
  timestamp.mFlags = .hostTimeValid
  timestamp.mHostTime = mach_absolute_time()
  var flags = AudioUnitRenderActionFlags()

  let result = delegate.deliverRecordedData(
    &flags, &timestamp, 0, frameCount,
    UnsafePointer(bufferList), nil, nil)
  if result != noErr {
    Logger.warn(
      type: .dummyAudioDevice,
      message: "deliverRecordedData failed with status \(result)")
  }
}

/// PCM データを生成する。
///
/// 単体テストから直接呼べるよう internal とし、サンプルレートは引数で受け取る。
func fillPCMData(data: UnsafeMutableRawPointer, frameCount: Int, sampleRate: Double = 48000) {
  let pcm = data.assumingMemoryBound(to: Int16.self)
  pcm.initialize(repeating: 0, count: frameCount)
  switch config.content {
  case .silence:
    break
  case .sineWave(let frequency):
    for i in 0..<frameCount {
      let value = Int16(sin(2.0 * .pi * frequency * phase) * 32767.0 * 0.3)
      pcm[i] = value
      // フレーム境界で位相が不連続にならないよう、位相を進めて保持する
      phase += 1.0 / sampleRate
    }
  }
}
```

### `terminateDevice` の実装

`RTCAudioDevice` のメンバーは ADM スレッドから呼ぶ契約のため、停止処理は `delegate.dispatchSync` 経由で ADM スレッドに束ねて実行する。`terminateDevice` は ADM 側の `Terminate`（PeerConnection 破棄時、`nativeChannel?.close()` 経由の `WebRtcVoiceEngine::Terminate`）からも呼ばれ得るが、`_isInitialized = false` と delegate の nil 化により二重呼び出しは安全である:

```swift
func terminateDevice() -> Bool {
  let stop: () -> Void = { [weak self] in
    guard let self else { return }
    self.recordingTimer?.cancel()
    self.recordingTimer = nil
    self._isRecording = false
    self._isRecordingInitialized = false
    self.audioUnit?.stopHardware()
    self.audioUnit = nil
    self._isPlaying = false
    self._isPlayoutInitialized = false
  }
  if let delegate {
    delegate.dispatchSync(stop)
  } else {
    stop()
  }
  delegate = nil
  _isInitialized = false
  return true
}
```

### Configuration 追加

```swift
// Configuration.swift に追加
public struct Configuration {
  /// ダミー音声を有効にするかどうか。
  /// true の場合、物理マイクの代わりにダミー音声を生成して送信します。
  /// この設定は接続確立時にのみ有効で、接続中の変更は反映されません。
  public var dummyAudioEnabled: Bool = false

  /// ダミー音声の内容
  public var dummyAudioContent: DummyAudioContent = .sineWave(frequency: 440)
}
```

### `DummyAudioContent` 型（新規ファイル）

```swift
// Sora/DummyAudioContent.swift (新規追加)
public enum DummyAudioContent: Sendable {
  case silence
  case sineWave(frequency: Double)
}
```

### `DummyAudioConfig` 型

`Configuration` のダミー音声関連プロパティを `NativePeerChannelFactory` に渡すための値型:

```swift
// Configuration.swift 内に追加
struct DummyAudioConfig {
  let initialMicrophoneEnabled: Bool
  let content: DummyAudioContent
}
```

### NativePeerChannelFactory の修正

`audioDeviceModule` プロパティの型を `RTCAudioDeviceModule?` に変更し、ダミー経路では `nil` とする。ダミー音声用の `RTCAudioDevice` は `dummyAudioDevice` プロパティで保持する。`dummyAudioDevice` は `NativePeerChannelFactory` の生成時に一度だけ設定し、以後変更しない:

```swift
// NativePeerChannelFactory.swift
final class NativePeerChannelFactory: @unchecked Sendable {
  let audioDeviceModule: RTCAudioDeviceModule?
  let audioDeviceModuleWrapper: AudioDeviceModuleWrapper?
  let dummyAudioDevice: DummyAudioDevice?
  var nativeFactory: RTCPeerConnectionFactory

  init(
    bypassVoiceProcessing: Bool,
    dummyAudioConfig: DummyAudioConfig? = nil
  ) {
    Logger.debug(type: .peerChannel, message: "create native peer channel factory")

    let encoder = WrapperVideoEncoderFactory.shared
    let decoder = RTCDefaultVideoDecoderFactory()

    if let config = dummyAudioConfig {
      let device = DummyAudioDevice(config: config)
      self.dummyAudioDevice = device
      self.audioDeviceModule = nil
      self.audioDeviceModuleWrapper = nil
      // ダミー音声有効時は bypassVoiceProcessing は無視される (Voice Processing 不要のため)
      if bypassVoiceProcessing {
        Logger.warn(
          type: .peerChannel,
          message: "bypassVoiceProcessing is ignored when dummy audio is enabled")
      }
      nativeFactory = RTCPeerConnectionFactory(
        encoderFactory: encoder,
        decoderFactory: decoder,
        audioDevice: device)  // id<RTCAudioDevice> を直接渡す
    } else {
      let adm = RTCAudioDeviceModule(bypassVoiceProcessing: bypassVoiceProcessing)
      self.dummyAudioDevice = nil
      self.audioDeviceModule = adm
      self.audioDeviceModuleWrapper = AudioDeviceModuleWrapper(audioDeviceModule: adm)
      nativeFactory = RTCPeerConnectionFactory(
        encoderFactory: encoder,
        decoderFactory: decoder,
        audioDeviceModule: adm)
    }

    for info in encoder.supportedCodecs() {
      Logger.debug(
        type: .peerChannel,
        message: "supported video encoder: \(info.name) \(info.parameters)")
    }
    for info in decoder.supportedCodecs() {
      Logger.debug(
        type: .peerChannel,
        message: "supported video decoder: \(info.name) \(info.parameters)")
    }
  }
}
```

### `dummyAudioEnabled` と `audioEnabled` の関係

| `role` | `dummyAudioEnabled` | `audioEnabled` | 動作 |
|---|---|---|---|
| `sendonly` / `sendrecv` | `false` | 任意 | 既存動作 |
| `sendonly` / `sendrecv` | `true` | `true` | カスタム `RTCAudioDevice` でダミー音声を送信。AUAudioUnit 経由で遠隔音声の再生も動作する |
| `sendonly` / `sendrecv` | `true` | `false` | 音声トラックは生成されないためダミー音声も無効（警告ログ出力） |
| `recvonly` | `true` | 任意 | 送信は発生しないが、`DummyAudioDevice` はファクトリに渡されるため再生経路が AUAudioUnit に置き換わる |

`DummyAudioDevice` の生成は `dummyAudioEnabled == true` であれば `role` や `audioEnabled` に関わらず行われる。

### PeerChannel の修正

`initializeSenderStream()` 内で、`dummyAudioEnabled == true` の場合は `initializeAudioInput()` をスキップする。AVAudioSession のカテゴリ設定は `DummyAudioDevice.initialize(with:)` が行うため、PeerChannel 側では何もしない:

```swift
// initializeSenderStream() 内 (PeerChannel.swift:626-628)
if configuration.audioEnabled {
  if !configuration.dummyAudioEnabled {
    initializeAudioInput()
  } else {
    Logger.debug(
      type: .peerChannel,
      message: "dummy audio enabled, skip initialize audio input")
  }
}
```

`dummyAudioEnabled == true` かつ `audioEnabled == false` の場合は、音声トラック自体が生成されないためダミー音声も無効となる。この場合に警告ログを出力する:

```swift
// initializeSenderStream() 内、音声トラック生成後に追加
if configuration.dummyAudioEnabled && !configuration.audioEnabled {
  Logger.warn(
    type: .peerChannel,
    message: "dummy audio enabled but audioEnabled is false, dummy audio is disabled")
}
```

#### 切断時の停止処理

`terminateDevice()` の呼び出しは切断処理（`basicDisconnect`）内、`if configuration.isSender { terminateSenderStream() }`（`PeerChannel.swift:1359-1361`）の**ガードブロックの直後（ガードの外側）**に置く。`terminateSenderStream` は送信側のカメラ停止のみを行い、音声デバイスの停止は行わないため、`recvonly` を含む全ロールで停止処理が必要である。また `nativeChannel?.close()`（`PeerChannel.swift:1378`）より前に置き、ADM スレッドが生存している状態で `terminateDevice` の `dispatchSync` を実行する:

```swift
// basicDisconnect() 内、isSender ガードの直後 (ガードの外側) に追加
if configuration.dummyAudioEnabled,
  let dummyDevice = nativePeerChannelFactory.dummyAudioDevice
{
  dummyDevice.terminateDevice()
}
```

`dummyAudioDevice` への nil 代入は行わない。切断後は `NativePeerChannelFactory` ごと破棄されるため、デバイスの解放はファクトリの破棄に委ねる。

### MediaChannel の修正

`MediaChannel.setAudioHardMute(_:)` を修正し、`audioDeviceModuleWrapper` が nil（ダミー音声有効）の場合に `DummyAudioDevice.setHardMute(_:)` を呼び出してハードミュートを切り替える。`initialMicrophoneEnabled` の契約（後から `setAudioHardMute(false)` で有効化）をダミー音声経路でも守るためである:

```swift
// MediaChannel.swift:669-693
public func setAudioHardMute(_ mute: Bool) -> Error? {
  guard state == .connected else { ... }
  guard configuration.audioEnabled else { ... }
  guard configuration.isSender else { ... }

  // 通常経路: RTCAudioDeviceModule のラッパーでハードミュートを切り替える
  if let wrapper = nativePeerChannelFactory.audioDeviceModuleWrapper {
    if !wrapper.setAudioHardMute(mute) {
      return SoraError.mediaChannelError(
        reason: "AudioDeviceModuleWrapper::setAudioHardMute failed")
    }
    return nil
  }

  // ダミー音声経路: DummyAudioDevice でハードミュートを切り替える
  if let dummyDevice = nativePeerChannelFactory.dummyAudioDevice {
    if !dummyDevice.setHardMute(mute) {
      return SoraError.mediaChannelError(
        reason: "DummyAudioDevice::setHardMute failed")
    }
    return nil
  }

  return SoraError.mediaChannelError(
    reason: "setAudioHardMute is not supported")
}
```

`NativePeerChannelFactory.init` 呼び出し（`MediaChannel.swift:242`）に `dummyAudioConfig` を追加する:

```swift
let dummyConfig: DummyAudioConfig? = {
  guard configuration.dummyAudioEnabled else { return nil }
  return DummyAudioConfig(
    initialMicrophoneEnabled: configuration.initialMicrophoneEnabled,
    content: configuration.dummyAudioContent)
}()

nativePeerChannelFactory = NativePeerChannelFactory(
  bypassVoiceProcessing: configuration.bypassVoiceProcessing,
  dummyAudioConfig: dummyConfig)
```

### Logger type の追加

`Logger` に新規 type `.dummyAudioDevice` を追加する。`Sora/Logger.swift` の変更内容:

- `LogType` enum に `.dummyAudioDevice` を追加
- `CustomStringConvertible` extension に `case .dummyAudioDevice: return "DummyAudioDevice"` を追加
- `Group.channels` の switch-case に `.dummyAudioDevice` を追加（デフォルトでログ出力有効）

### スレッド安全性

- `recordingTimer` の生成・キャンセルは `startRecording` / `stopRecording` / `terminateDevice` で同期的に行う
- `terminateDevice` は切断処理（シグナリング系スレッド）から呼ばれるため、`delegate.dispatchSync` 経由で停止処理を ADM スレッドに束ねて実行する（`RTCAudioDevice.h` の「同じスレッドから呼ぶ」契約）。`dispatchSync` は ADM スレッドからの再入時はインライン実行されるためデッドロックしない
- `DummyAudioDevice` は非 Sendable のオーディオオブジェクト（`AUAudioUnit` / `DispatchSourceTimer`）を保持する。Swift 6 の strict concurrency でコンパイルエラーになる場合は `NativePeerChannelFactory` と同様に `@unchecked Sendable` を付与する（実装時に `-strict-concurrency=complete` で検証する）
- 状態フラグへの書き込みは ADM スレッドと切断処理スレッドから発生するが、ダミー用途では競合による実害はない

### エッジケース

- AUAudioUnit の生成失敗時: `initializePlayout` は `false` を返し、`startPlayout` も `false` を返す。この場合ダミー音声の送信は継続するが再生は無効となる（`Logger.warn(type: .dummyAudioDevice)` で警告ログを出力する）
- ダミー音声有効時の `setAudioSoftMute`: 通常通り `audioEnabled` の切り替えで動作する
- バックグラウンド遷移時: `DispatchSourceTimer` はバックグラウンドでも動作するが、システムがサスペンドした場合は停止する。`AUAudioUnit` も同様にサスペンドされる。許容する
- フレーム生成の異常時（フレーム数不正・malloc 失敗・`deliverRecordedData` 失敗）は警告ログを出力してスキップする。タイマー間隔（20ms）ごとにログが連発し得るが、ダミー用途では発生確率が低いため許容する
- `isSender` の場合、接続時に Offer SDP 作成（`createClientOfferSDP`）が実行され、その際に ADM の初期化（`DummyAudioDevice.initialize(with:)`）が走る。Offer 作成のたびに録音タイマーの開始・停止が発生し得るため、`startRecording` は再入安全でなければならない（既存タイマーのキャンセルで対応済み）。実装時に Offer 作成 → close → 接続のフローでタイマーの動作を確認する
- AVAudioSession 割り込み時: `notifyAudioInputInterrupted` / `notifyAudioOutputInterrupted` を delegate 経由で WebRTC に通知する実装は本 issue のスコープ外。割り込み発生時はシステムの既定動作に任せる

### 制限事項

- `DummyAudioDevice` は `bypassVoiceProcessing` に非対応。ダミー音声有効時に `bypassVoiceProcessing = true` を指定した場合は警告ログを出力して無視する
- `pauseRecording` / `resumeRecording` は `RTCAudioDeviceModule` の API であり、`RTCAudioDevice` プロトコルには存在しない。ダミー音声有効時は `DummyAudioDevice.setHardMute(_:)` が `MediaChannel.setAudioHardMute(_:)` から呼ばれ、ハードミュートとして動作する（録音データの送信を停止する）
- 録音は `DispatchSourceTimer` による定期生成のため、リアルタイムオーディオの品質（タイミングジッタ）は保証されない。ダミー用途として許容する
- `DummyAudioContent.sineWave` の周波数はナイキスト周波数（サンプルレートの半分）以下を想定する。超過時はエイリアシングが発生する
- Sora の公開音声 API（`Sora.audioEnabled` / `Sora.usesManualAudio` / `Sora.setAudioMode`）は `RTCAudioSession` 経由で動作するため、ダミー音声有効時は無効化または競合する。ダミー音声と組み合わせて使用しないこと
- `Configuration.initialMicrophoneEnabled` は `initializeAudioInput()` 内の `setInitialMicrophoneMute` で適用されるが、ダミー音声有効時は `DummyAudioDevice` が `isHardMuted` として初期状態に反映する。`initialMicrophoneEnabled = false` の場合は初期状態でミュートされ、`setAudioHardMute(false)` で有効化できる
- `initialize(with:)` で設定した AVAudioSession（`playAndRecord` + アクティブ状態）は切断後も復元されない。アプリの既存カテゴリ設定は上書きされるため、復元はアプリ側で行うこと
- `kAudioUnitSubType_RemoteIO` はシミュレーターで利用できない可能性がある（iOS シミュレーターは macOS のオーディオ基盤を使用するため）。シミュレーターで「音声が聞こえる」ことを確認する場合は、実装時に RemoteIO の動作を実測し、必要な代替（`kAudioUnitSubType_GenericOutput` 等）や制限事項への反映を検討する
- `MediaChannel` は公式には再利用不可（一度接続した `MediaChannel` の再 `connect` は保証されない）。再接続は新規 `MediaChannel`（新規 `NativePeerChannelFactory`、新規 `DummyAudioDevice`）で行うこと

## テスト戦略

AGENTS.md の「モックやスタブは絶対に利用しないこと」に従い、`RTCAudioDeviceDelegate` のテストダブルは作成しない。PCM 生成ロジックを internal 関数（`fillPCMData`）として分離し、モック不要の単体テストと、実際の接続を使う E2E テストで検証する。

### 単体テスト

テストファイル: `SoraTests/DummyAudioDeviceTests.swift`

- `fillPCMData` が `.silence` で全サンプル 0 を生成すること
- `fillPCMData` が `.sineWave(frequency:)` で期待する周波数のサンプルを生成すること（サンプルレート 48000 Hz、周波数 440 Hz の場合、**負→正の符号反転**が 1 秒あたり 440 ± 1 回発生することを利用して検証する。位相が 0 から始まるため先頭サンプルは 0 になり、境界の扱い（`s[i-1] < 0 && s[i] >= 0`）で ±1 のずれが生じるため、範囲判定にする）
- `fillPCMData` がフレーム境界を跨いでも位相が連続すること（クリックノイズ防止の検証）
- `initialMicrophoneEnabled = false` の場合、初期状態でハードミュートされること（`Configuration.initialMicrophoneEnabled` の契約）
- `setHardMute(_:)` でハードミュート状態が切り替わること（`setAudioHardMute` の契約）

`DummyAudioDevice` のライフサイクル（`initialize(with:)` / `terminateDevice` 等）は実際の ADM 経由でのみ動作するため、E2E テストで検証する。

### E2E テスト

`SoraTests/SignalingE2ETests.swift` に `DummyVideoCapturer` の先例（`testSendonlyDummyVideo`）に倣って追加する。既存の E2E テストが `setUp` / `tearDown` で `Logger.shared.level` を保存・復元している先例（`SignalingE2ETests.swift:20-31`）に倣い、`AVAudioSession` の状態も保存・復元する:

- `setUp` で `AVAudioSession.sharedInstance()` の `category` / `mode` / `categoryOptions` を保存する（`isActive` は取得 API がないため保存しない）
- ダミー音声テストのみ `audioSessionActivatedByTest` フラグを true にし、`tearDown` はフラグが true の場合のみ復元する（毎回 `setActive(false)` すると、AVAudioSession に触れない他の E2E テストが前提とする音声状態を壊すため）
- テストは `role: .sendonly`、`videoEnabled: false`、`audioEnabled: true`、`dummyAudioEnabled: true` の構成で接続し、`onConnect` が呼ばれることを確認する
- `getStats()` で音声コーデック（`codec` / `mimeType == "audio/opus"`）と音声トラック（`kind == "audio"` の outbound-rtp）の存在、`bytesSent` / `packetsSent` が 0 より大きいことを確認する（ダミー音声が実際に送信されていることの確認。sora-js-sdk の E2E と同様）
- `tearDown` はフラグが true の場合のみ、保存した `category` / `mode` / `categoryOptions` に復元し、`setActive(false)` で非アクティブ化する（`DummyAudioDevice` が変更したグローバル状態が後続テストに影響しないようにする）

CI 環境に音声出力デバイスが存在する必要がある（`initialize(with:)` の `setActive(true)` と AUAudioUnit の生成が音声出力デバイスに依存するため）。sendonly 構成なら再生は初期化されず影響は小さいが、これは libwebrtc の ADM の内部挙動に依存するため、実装時に sendonly 構成でも再生が初期化される場合はテスト設計を見直す。

### 手動テスト

- シミュレーター上で `dummyAudioEnabled = true` を設定し、Sora への接続が成功すること（受信側でダミー音声（正弦波 440Hz）が聞こえることを確認する）
- `sendrecv` で `dummyAudioEnabled = true` を設定し、遠隔参加者の音声が本デバイスのスピーカーから聞こえることを確認すること（`.defaultToSpeaker` によりスピーカー出力になる）
- `recvonly` で `dummyAudioEnabled = true` を設定し、遠隔音声の再生が AUAudioUnit 経由で動作することを確認すること
- `dummyAudioEnabled = false`（デフォルト）の場合、既存のマイク入力・再生に影響がないこと

## 変更ファイル一覧

- `Sora/Configuration.swift` — `dummyAudioEnabled`, `dummyAudioContent`, `DummyAudioConfig` を追加
- `Sora/DummyAudioContent.swift` — `DummyAudioContent` enum を新規追加
- `Sora/DummyAudioDevice.swift` — `RTCAudioDevice` プロトコル実装クラスを新規追加（Swift）、ハードミュート制御（`isHardMuted` / `setHardMute(_:)`）を含む
- `Sora/NativePeerChannelFactory.swift` — `audioDeviceModule` の Optional 化、ダミー経路での `init(encoderFactory:decoderFactory:audioDevice:)` 使用、`dummyAudioDevice` プロパティ追加
- `Sora/MediaChannel.swift` — `NativePeerChannelFactory.init` 呼び出しに `dummyAudioConfig` を追加、`setAudioHardMute` のダミー音声対応（`DummyAudioDevice.setHardMute(_:)` への委譲）
- `Sora/PeerChannel.swift` — `dummyAudioEnabled` 時の `initializeAudioInput()` スキップ、切断時の `DummyAudioDevice` 停止処理追加、警告ログ追加
- `Sora/Logger.swift` — `LogType` enum に `.dummyAudioDevice` を追加、`Group.channels` に追記
- `SoraTests/DummyAudioDeviceTests.swift` — 新規追加（`fillPCMData` とハードミュート制御の単体テスト）
- `SoraTests/SignalingE2ETests.swift` — ダミー音声の E2E テスト追加
- `CHANGES.md` — develop セクションの [ADD] エントリ群の後ろに以下を追記:
  - [ADD] Configuration にダミー音声の設定を追加する
    - `dummyAudioEnabled` が `true` の場合、物理マイクの代わりにダミー音声（正弦波/無音）を生成して送信する
    - `RTCAudioDevice` プロトコルを実装したカスタム音声デバイスで PCM データを注入する
    - 遠隔音声の再生は AUAudioUnit（RemoteIO）経由で実装する
    - @担当者（実装時に確定する）

実装時に `make fmt`（swift-format）と SwiftLint を実行してコードスニペットのフォーマットを整形すること。

## 完了条件

- [x] `DummyAudioDevice` が `RTCAudioDevice` プロトコルの全必須プロパティ/メソッドを実装し、設計方針のテーブルに従った値を返すこと
- [x] 受信側で 440Hz 正弦波が聞こえること（`deliverRecordedData` 経由の PCM 注入の確認。手動テストセクション参照）
- [x] AUAudioUnit 経由での遠隔音声の再生が動作し、`sendrecv` モードで双方向の音声通信が可能であること（手動テストセクション参照）
- [x] `.silence` と `.sineWave(frequency:)` の両方の `DummyAudioContent` が正しく動作すること
- [x] `initialMicrophoneEnabled = false` で初期ミュートされ、`setAudioHardMute(false)` で有効化できること（`Configuration.initialMicrophoneEnabled` の契約をダミー音声経路でも守ること）
- [x] `dummyAudioEnabled == false`（デフォルト）の場合、既存のマイク入力・再生に影響がないこと
- [x] 切断時に `DummyAudioDevice` が適切に停止され（`recvonly` を含む全ロール）、再接続（新規 `MediaChannel`）時にも正しく動作すること
- [x] `fillPCMData` の単体テストとダミー音声の E2E テストが実装され、すべて成功すること
- [x] `CHANGES.md` に変更履歴が追記されていること

## 解決方法

- `Sora/DummyAudioDevice.swift` を新規追加した
  - `RTCAudioDevice` プロトコル実装。`DispatchSourceTimer` で PCM 16-bit データを生成し `delegate.deliverRecordedData` で ADM に注入する（録音）
  - `AUAudioUnit`（RemoteIO）の `outputProvider` 経由で `delegate.getPlayoutData` を呼び、遠隔音声を再生する
  - `AVAudioSession` の設定（`playAndRecord` + `.defaultToSpeaker`）を `initialize(with:)` で行う（`RTCAudioDevice.h` の契約）
  - ハードミュート制御（`isHardMuted` / `setHardMute(_:)`）を実装し、`initialMicrophoneEnabled` の契約をダミー音声経路でも守る
- `Sora/DummyAudioContent.swift` を新規追加した（`silence` / `sineWave(frequency:)`）
- `Sora/Configuration.swift` に `dummyAudioEnabled` / `dummyAudioContent` / `DummyAudioConfig` を追加した
- `Sora/NativePeerChannelFactory.swift` を修正した
  - `audioDeviceModule` を Optional 化し、ダミー経路では `RTCPeerConnectionFactory.init(encoderFactory:decoderFactory:audioDevice:)` を使用する
  - `dummyAudioDevice` プロパティを追加した
- `Sora/MediaChannel.swift` を修正した
  - `NativePeerChannelFactory.init` に `dummyAudioConfig` を渡す
  - `setAudioHardMute` をダミー音声対応にした（`DummyAudioDevice.setHardMute(_:)` への委譲）
- `Sora/PeerChannel.swift` を修正した
  - `dummyAudioEnabled` 時の `initializeAudioInput()` をスキップする
  - 切断時（`basicDisconnect` の isSender ガード外）に `DummyAudioDevice.terminateDevice()` を実行する
- `Sora/Logger.swift` に `LogType.dummyAudioDevice` を追加した（`Group.channels` に属する）
- テストを追加した
  - `SoraTests/DummyAudioDeviceTests.swift`: `fillPCMData` の PCM 生成とハードミュート制御の単体テスト 6 件
  - `SoraTests/SignalingE2ETests.swift`: `testSendonlyDummyAudio`（getStats で audio codec / outbound-rtp / bytesSent / packetsSent を確認）。CI で通過済み
- `CHANGES.md` の develop セクションに [ADD] エントリを追記した
