# ダミー音声を流す仕組みを追加する

- Priority: Medium
- Created: 2026-06-08
- Completed:
- Model: deepseek-v4-pro
- Branch: feature/add-dummy-audio-source
- Polished: 2026-06-09

## 目的

Sora iOS SDK を利用したアプリケーションのテストやデモにおいて、物理的なマイクを使用せずにダミーの音声データを生成して送信できる仕組みを提供する。また、受信した遠隔音声の再生も引き続き動作する。

`0067-add-dummy-video-source` のダミー映像と組み合わせることで、シミュレーターや CI 環境で完全なメディア通信テストが可能になる。

## 調査結果（解決済み）

実装にあたり調査した項目の結論:

### 実装言語: Swift（`.mm` 不要）

`RTCAudioDevice.h` には C++ 依存（`std::`、`#ifdef __cplusplus`、`webrtc::` 名前空間）が一切なく、全型が Foundation / CoreAudio / GCD の C 型で構成されている。Sora プロジェクト内でも `PeerChannel: RTCPeerConnectionDelegate` など 6 箇所で ObjC プロトコルへの Swift 準拠の前例がある。`.mm` の SPM ビルド設定問題を回避し、Swift での実装とする。

### 再生: AUAudioUnit を使用

`DummyAudioDevice` は `RTCAudioDevice` プロトコル全体を実装するため、ダミー音声の送信（録音）だけでなく遠隔音声の再生も自前で行う必要がある。`AUAudioUnit` の `outputProvider` ブロック経由で `delegate.getPlayoutData` を呼ぶ方式を採用する。`AVAudioEngine` よりコード量が少なく、再生経路のみ必要な本ユースケースに適している。`AUAudioUnit` は iOS 8.0+ で利用可能であり、本 SDK の iOS 14 要件を満たす。

参考実装: [mstyura/RTCAudioDevice](https://github.com/mstyura/RTCAudioDevice) の `AUAudioUnitRTCAudioDevice.swift`

### AudioBufferList のメモリ管理: malloc/free でよい

フレームあたりのアロケーションは約 984 bytes（AudioBufferList 24 bytes + データ 960 bytes）、秒間約 98 KB。iOS デバイスにとって無視できる量であり、事前確保による「解放済みメモリへの誤アクセス」リスクを避けるため、malloc/free のシンプルな方式を採用する。「Premature Optimization is the Root of All Evil」に従い、計測可能な問題が発生しない限り最適化しない。

## 現状

音声入力は `RTCAudioDeviceModule` （WebRTC フレームワークの ObjC クラス）を通じて管理され、物理マイクからの音声データが `RTCAudioTrack` に流される：

```swift
// NativePeerChannelFactory.swift:43-67
class NativePeerChannelFactory {
    let audioDeviceModule: RTCAudioDeviceModule

    init(bypassVoiceProcessing: Bool) {
        audioDeviceModule = RTCAudioDeviceModule(bypassVoiceProcessing: bypassVoiceProcessing)
        nativeFactory = RTCPeerConnectionFactory(
            encoderFactory: encoder,
            decoderFactory: decoder,
            audioDeviceModule: audioDeviceModule)
    }
}
```

`RTCAudioDeviceModule` は `RTCPeerConnectionFactory` の初期化時に渡され、接続単位で管理される。このクラスにはサブクラス化や delegate による音声データ注入の API は存在しない。

## 関連 issue

`0019-investigate-audio-source-mixing` でも `RTCAudioDeviceModule` の差し替えを調査対象としている。本 issue は 0019 とは独立して実装する。`RTCPeerConnectionFactory.initWithEncoderFactory:decoderFactory:audioDevice:` の実在は `RTCPeerConnectionFactory.h` で確認済みである。

## 設計方針

### 全体方針

- `RTCAudioDevice` プロトコルを実装した `DummyAudioDevice` クラスを **Swift** で作成する。ObjC プロトコルへの Swift 準拠は Sora プロジェクト内に 6 件の前例（`PeerChannel: RTCPeerConnectionDelegate` 等）があり、問題なく可能
- ダミー音声の送信（録音）は `DispatchSource.makeTimerSource()` で生成した PCM 16-bit integer データを `delegate.deliverRecordedData` で注入する
- 遠隔音声の再生は `AUAudioUnit` の `outputProvider` ブロックで `delegate.getPlayoutData` を呼び出す
- `DummyAudioDevice` を `RTCPeerConnectionFactory.init(encoderFactory:decoderFactory:audioDevice:)` に直接渡す
- `NativePeerChannelFactory` を修正し、ダミー音声有効時にカスタム `RTCAudioDevice` を使用する
- `Configuration` にダミー音声の設定を追加する

### `RTCAudioDevice` プロトコル実装の責務

以下は `RTCAudioDevice.h` の実際の定義に基づく。`DummyAudioDevice` は全 13 プロパティ + 8 メソッドを実装する必要がある:

| プロパティ/メソッド | 戻り値の型 | ダミー実装での動作 |
|---|---|---|
| `deviceInputSampleRate` | `double` | `delegate.preferredInputSampleRate` を返す |
| `inputIOBufferDuration` | `NSTimeInterval` | `delegate.preferredInputIOBufferDuration` を返す |
| `inputNumberOfChannels` | `NSInteger` | `dummyAudioChannelCount` を返す |
| `inputLatency` | `NSTimeInterval` | 0 を返す |
| `deviceOutputSampleRate` | `double` | `delegate.preferredOutputSampleRate` を返す |
| `outputIOBufferDuration` | `NSTimeInterval` | `delegate.preferredOutputIOBufferDuration` を返す |
| `outputNumberOfChannels` | `NSInteger` | `dummyAudioChannelCount` を返す |
| `outputLatency` | `NSTimeInterval` | 0 を返す |
| `isInitialized` | `BOOL` | `initializeWithDelegate` 呼び出し後は `true` |
| `isPlayoutInitialized` | `BOOL` | `initializePlayout` 呼び出し後は `true` |
| `isPlaying` | `BOOL` | `startPlayout` 呼び出し後は `true` |
| `isRecordingInitialized` | `BOOL` | 常に `true` |
| `isRecording` | `BOOL` | `startRecording` 呼び出し後は `true` |
| `initializeWithDelegate:` | `BOOL` | delegate を保持し `true` を返す |
| `terminateDevice` | `BOOL` | 録音タイマーを停止、AUAudioUnit を停止・解放、delegate を nil にし `true` を返す |
| `initializePlayout` | `BOOL` | AUAudioUnit を生成・設定し `true` を返す。失敗時は `false` |
| `startPlayout` | `BOOL` | `auAudioUnit.startHardware()` を呼び `true` を返す |
| `stopPlayout` | `BOOL` | `auAudioUnit.stopHardware()` を呼び `true` を返す |
| `initializeRecording` | `BOOL` | 何もせず `true` を返す |
| `startRecording` | `BOOL` | `DispatchSourceTimer` を開始し `true` を返す |
| `stopRecording` | `BOOL` | `DispatchSourceTimer` をキャンセルし `true` を返す |

入出力のサンプルレート・IO バッファ期間は `delegate.preferred*` の値を使用することで、libwebrtc 内部での不要なリサンプリングを回避する。

### `DummyAudioDevice` Swift 実装（全体構造）

```swift
// Sora/DummyAudioDevice.swift (新規追加)
import Foundation
import WebRTC
import AVFAudio

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
    private var _isRecording = false

    init(config: DummyAudioConfig) {
        self.config = config
        super.init()
    }

    // MARK: - RTCAudioDevice プロパティ

    var deviceInputSampleRate: Double {
        delegate?.preferredInputSampleRate ?? config.sampleRate
    }

    var inputIOBufferDuration: TimeInterval {
        delegate?.preferredInputIOBufferDuration ?? 0.02
    }

    var inputNumberOfChannels: Int { config.channelCount }

    var inputLatency: TimeInterval { 0 }

    var deviceOutputSampleRate: Double {
        delegate?.preferredOutputSampleRate ?? config.sampleRate
    }

    var outputIOBufferDuration: TimeInterval {
        delegate?.preferredOutputIOBufferDuration ?? 0.02
    }

    var outputNumberOfChannels: Int { config.channelCount }

    var outputLatency: TimeInterval { 0 }

    var isInitialized: Bool { _isInitialized }
    var isPlayoutInitialized: Bool { _isPlayoutInitialized }
    var isPlaying: Bool { _isPlaying }
    var isRecordingInitialized: Bool { true }
    var isRecording: Bool { _isRecording }
}
```

### 再生（Playout）の実装

`initializePlayout` で AUAudioUnit（RemoteIO）を生成し、`outputProvider` ブロックで `delegate.getPlayoutData` を呼び出す:

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
        return false
    }
    au.isOutputEnabled = true
    au.isInputEnabled = false  // 録音は別経路（タイマー）のため入力不要
    au.maximumFramesToRender = 1024

    let getPlayoutData = delegate.getPlayoutData
    au.outputProvider = { (actionFlags, timestamp, frameCount, _, outputData) -> AUAudioUnitStatus in
        return getPlayoutData(actionFlags, timestamp, 0, frameCount, outputData)
    }

    do {
        try au.allocateRenderResources()
    } catch {
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

`startRecording` で `DispatchSource.makeTimerSource()` を使い、`delegate.deliverRecordedData` で PCM データを注入する。`delegate.dispatchAsync` で ADM スレッドに移動すること:

```swift
func startRecording() -> Bool {
    guard let delegate else { return false }
    _isRecording = true

    delegate.dispatchAsync { [weak self] in
        guard let self else { return }

        let timer = DispatchSource.makeTimerSource(queue: self.recordingQueue)
        let interval = self.delegate?.preferredInputIOBufferDuration ?? 0.02
        let intervalNs = Int(interval * Double(NSEC_PER_SEC))

        timer.schedule(deadline: .now(), repeating: .nanoseconds(intervalNs))
        timer.setEventHandler { [weak self] in
            self?.deliverPCMData()
        }
        timer.resume()
        self.recordingTimer = timer
    }
    return true
}

func stopRecording() -> Bool {
    recordingTimer?.cancel()
    recordingTimer = nil
    _isRecording = false
    return true
}

private func deliverPCMData() {
    guard let delegate, _isRecording else { return }

    let frameCount = UInt32(
        delegate.preferredInputSampleRate * delegate.preferredInputIOBufferDuration)
    let channelCount = config.channelCount
    let dataSize = Int(frameCount) * channelCount * MemoryLayout<Int16>.size

    let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
    bufferList.pointee.mNumberBuffers = 1
    bufferList.pointee.mBuffers.mNumberChannels = UInt32(channelCount)
    bufferList.pointee.mBuffers.mDataByteSize = UInt32(dataSize)
    bufferList.pointee.mBuffers.mData = malloc(dataSize)

    if let data = bufferList.pointee.mBuffers.mData {
        fillPCMData(data: data, frameCount: Int(frameCount), channelCount: channelCount)
    }

    var flags = AudioUnitRenderActionFlags()
    var timestamp = AudioTimeStamp()
    delegate.deliverRecordedData(
        &flags, &timestamp, 0, frameCount,
        UnsafePointer(bufferList), nil, nil)

    free(bufferList.pointee.mBuffers.mData)
    bufferList.deallocate()
}

private func fillPCMData(data: UnsafeMutableRawPointer, frameCount: Int, channelCount: Int) {
    let pcm = data.assumingMemoryBound(to: Int16.self)
    switch config.content {
    case .silence:
        pcm.initialize(repeating: 0, count: frameCount * channelCount)
    case .sineWave(let frequency):
        let sampleRate = delegate?.preferredInputSampleRate ?? config.sampleRate
        for i in 0..<frameCount {
            let t = Double(i) / sampleRate
            let value = Int16(sin(2.0 * .pi * frequency * t) * 32767.0 * 0.3)
            for ch in 0..<channelCount {
                pcm[i * channelCount + ch] = value
            }
        }
    }
}
```

### `terminateDevice` の実装

```swift
func terminateDevice() -> Bool {
    recordingTimer?.cancel()
    recordingTimer = nil
    _isRecording = false

    audioUnit?.stopHardware()
    audioUnit = nil
    _isPlaying = false
    _isPlayoutInitialized = false

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

    /// ダミー音声のサンプルレート（Hz）。
    /// delegate.preferredInputSampleRate と異なる値が指定された場合、
    /// libwebrtc 内部でリサンプリングが発生する可能性があります。
    public var dummyAudioSampleRate: Double = 48000

    /// ダミー音声のチャネル数
    public var dummyAudioChannelCount: Int = 1

    /// ダミー音声の内容
    public var dummyAudioContent: DummyAudioContent = .sineWave(frequency: 440)
}

// DummyAudioContent.swift (新規追加)
public enum DummyAudioContent: Sendable {
    case silence
    case sineWave(frequency: Double)
}
```

### `DummyAudioConfig` 型

`Configuration` のダミー音声関連プロパティを `NativePeerChannelFactory` に渡すための値型：

```swift
// Configuration.swift 内に追加
struct DummyAudioConfig {
    let sampleRate: Double
    let channelCount: Int
    let content: DummyAudioContent
}
```

### NativePeerChannelFactory の修正

`audioDeviceModule` プロパティの型を `RTCAudioDeviceModule?` に変更し、ダミー経路では `nil` とする。ダミー音声用の `RTCAudioDevice` は別プロパティで保持する：

```swift
// NativePeerChannelFactory.swift
final class NativePeerChannelFactory: @unchecked Sendable {
    var audioDeviceModule: RTCAudioDeviceModule?
    let audioDeviceModuleWrapper: AudioDeviceModuleWrapper?
    let dummyAudioDevice: DummyAudioDevice?
    var nativeFactory: RTCPeerConnectionFactory

    init(bypassVoiceProcessing: Bool, dummyAudioConfig: DummyAudioConfig?) {
        Logger.debug(type: .peerChannel, message: "create native peer channel factory")

        let encoder = WrapperVideoEncoderFactory.shared
        let decoder = RTCDefaultVideoDecoderFactory()

        if let config = dummyAudioConfig {
            let device = DummyAudioDevice(config: config)
            self.dummyAudioDevice = device
            self.audioDeviceModule = nil
            self.audioDeviceModuleWrapper = nil
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

ダミー音声有効時はハードミュートの概念自体が不要である。`MediaChannel.setAudioHardMute` が呼ばれた場合、`audioDeviceModuleWrapper` が nil であるため `guard let` でガードし、警告ログを出力して何もしない。

### `dummyAudioEnabled` と `audioEnabled` の関係

| `role` | `dummyAudioEnabled` | `audioEnabled` | 動作 |
|---|---|---|---|
| `sendonly`/`sendrecv` | `false` | 任意 | 既存動作 |
| `sendonly`/`sendrecv` | `true` | `true` | カスタム `RTCAudioDevice` でダミー音声を送信。AUAudioUnit 経由で遠隔音声の再生も動作する |
| `sendonly`/`sendrecv` | `true` | `false` | 音声トラックは生成されないためダミー音声も無効（警告ログ出力）。AUAudioUnit も生成されない |
| `recvonly` | 任意 | 任意 | `initializeSenderStream()` は呼ばれないため無効 |

ダミー音声有効時、再生は AUAudioUnit（RemoteIO）経由で動作する。受信のみで送信不要の場合（`sendonly` だが実際の送信を望まない等）でも、音声トラックは生成され SDP でオファーされる。

### PeerChannel の修正

`initializeAudioInput()` (`PeerChannel.swift:543-589`) は、`dummyAudioEnabled == true` の場合はスキップする。ただし受信側の音声再生のため `RTCAudioSession` のカテゴリ設定は必要であり、`dummyAudioEnabled` に関わらず実行する:

```swift
// initializeSenderStream() 内 (PeerChannel.swift:526-528)
if configuration.audioEnabled {
    if !configuration.dummyAudioEnabled {
        initializeAudioInput()
    } else {
        // AUAudioUnit 経由で再生するため、session.initializeInput は不要。
        // ただしカテゴリは playAndRecord に設定済みであること。
        isAudioInputInitialized = true
    }
}
```

`isAudioInputInitialized` は `true` に設定することで、再接続時に「既に初期化済み」と判定されず正しく再初期化される。

#### `terminateSenderStream()` の修正

ダミー音声キャプチャの停止処理を追加する:

```swift
// terminateSenderStream() の先頭付近に追加
if configuration.dummyAudioEnabled,
   let dummyDevice = nativePeerChannelFactory.dummyAudioDevice
{
    dummyDevice.stopRecording()
    dummyDevice.stopPlayout()
    dummyDevice.terminateDevice()
    nativePeerChannelFactory.dummyAudioDevice = nil
}
```

`terminateDevice()` は録音タイマー停止 + AUAudioUnit 停止 + delegate 解放を一度に行うため、`stopRecording`/`stopPlayout` を個別に呼ばなくても `terminateDevice` のみでよい。ただし明示的に `stopRecording`/`stopPlayout` を先に呼ぶことで、状態遷移を追跡しやすくする。

### MediaChannel の修正

`MediaChannel.setAudioHardMute(_:)` を修正し、`audioDeviceModuleWrapper` が nil の場合をガードする:

```swift
// MediaChannel.swift:660-684
public func setAudioHardMute(_ mute: Bool) -> Error? {
    guard state == .connected else { ... }
    guard configuration.audioEnabled else { ... }
    guard configuration.isSender else { ... }
    guard let wrapper = nativePeerChannelFactory.audioDeviceModuleWrapper else {
        Logger.warn(type: .mediaChannel,
            message: "setAudioHardMute called but audioDeviceModuleWrapper is nil (dummy audio enabled)")
        return nil
    }
    if !wrapper.setAudioHardMute(mute) {
        return SoraError.mediaChannelError(
            reason: "AudioDeviceModuleWrapper::setAudioHardMute failed")
    }
    return nil
}
```

`NativePeerChannelFactory.init` 呼び出し（`MediaChannel.swift:238`）に `dummyAudioConfig` を追加する:

```swift
let dummyConfig: DummyAudioConfig? = {
    guard configuration.dummyAudioEnabled else { return nil }
    return DummyAudioConfig(
        sampleRate: configuration.dummyAudioSampleRate,
        channelCount: configuration.dummyAudioChannelCount,
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
- `Group.audio` の switch-case に `.dummyAudioDevice` を追加（ユーザー指定時のみログ出力有効）

### エッジケース

- `dummyAudioEnabled == true` かつ切断時: `terminateSenderStream()` で `DummyAudioDevice` の停止処理を行う（`stopRecording` → `stopPlayout` → `terminateDevice` の順で停止し、`dummyAudioDevice` を nil に設定）
- AUAudioUnit の生成失敗時: `initializePlayout` は `false` を返し、`startPlayout` も `false` を返す。この場合ダミー音声の送信は継続するが再生は無効となる（警告ログ出力）
- ダミー音声有効時の `setAudioSoftMute`: 通常通り `audioEnabled` の切り替えで動作する
- 再接続時: `terminateSenderStream()` で `DummyAudioDevice` を破棄し、`initializeSenderStream()` で新規生成
- バックグラウンド遷移時: `DispatchSourceTimer` はバックグラウンドでも動作するが、システムがサスペンドした場合は停止する。`AUAudioUnit` も同様にサスペンドされる。許容する
- `deliverRecordedData` ブロック呼び出し時の `AudioBufferList` 解放漏れ: 毎回 malloc/free し、`defer` で解放漏れを防ぐ
- AVAudioSession 割り込み時: `notifyAudioInputInterrupted` / `notifyAudioOutputInterrupted` を delegate 経由で WebRTC に通知する実装は本 issue のスコープ外。割り込み発生時はシステムの既定動作に任せる

### 制限事項

- `DummyAudioDevice` は `bypassVoiceProcessing` に非対応。Voice Processing が不要なダミー音声では問題にならない
- `pauseRecording` / `resumeRecording` は `RTCAudioDeviceModule` の API であり、`RTCAudioDevice` プロトコルには存在しない。ダミー音声有効時はハードミュート機能が無効化される
- `AUAudioUnit` の出力フォーマット設定は行わず、システムのデフォルトに従う。`delegate.preferredOutputSampleRate` が 48000 Hz であれば、RemoteIO が自動的に適切なフォーマットを選択する

## テスト戦略

### 手動テスト

- シミュレーター上で `dummyAudioEnabled = true` を設定し、Sora への接続が成功すること
  - ICE 接続が確立し `onConnect` が呼ばれること
  - 受信側でダミー音声（正弦波 440Hz）が聞こえることを確認すること
- `sendrecv` で `dummyAudioEnabled = true` を設定し、遠隔参加者の音声が本デバイスのスピーカーから聞こえることを確認すること
- `dummyAudioEnabled = false`（デフォルト）の場合、既存のマイク入力・再生に影響がないこと
- 切断後に `DummyAudioDevice` が正しく停止され、再接続時にも問題なく動作すること

### 単体テスト

テストファイル: `SoraTests/DummyAudioDeviceTests.swift`

- `DummyAudioDevice` のライフサイクル（`initializeWithDelegate` / `terminateDevice`）が正しく状態を切り替えること
- `startRecording` / `stopRecording` による `isRecording` の切り替えが正しいこと
- `initializePlayout` / `startPlayout` / `stopPlayout` による `isPlayoutInitialized` / `isPlaying` の状態遷移が正しいこと
- 生成された PCM データが期待するサンプルレート・チャネル数・周波数であること
- `.silence` と `.sineWave(frequency:)` の両方で正しいデータが生成されること
- `delegate` が nil の状態で `startRecording` / `startPlayout` を呼んだ場合に適切に処理されること

## 変更ファイル一覧

- `Sora/Configuration.swift` — `dummyAudioEnabled`, `dummyAudioSampleRate`, `dummyAudioChannelCount`, `dummyAudioContent`, `DummyAudioConfig` を追加
- `Sora/DummyAudioContent.swift` — `DummyAudioContent` enum を新規追加
- `Sora/DummyAudioDevice.swift` — `RTCAudioDevice` プロトコル実装クラスを新規追加（Swift）
- `Sora/NativePeerChannelFactory.swift` — `audioDeviceModule` の Optional 化、ダミー経路での `init(encoderFactory:decoderFactory:audioDevice:)` 使用、`dummyAudioDevice` プロパティ追加
- `Sora/MediaChannel.swift` — `NativePeerChannelFactory.init` 呼び出しに `dummyAudioConfig` を追加、`setAudioHardMute` の Optional 対応
- `Sora/PeerChannel.swift` — `dummyAudioEnabled` 時の `initializeAudioInput()` スキップ、`terminateSenderStream()` への `DummyAudioDevice` 停止処理追加
- `Sora/Logger.swift` — `LogType` enum に `.dummyAudioDevice` を追加、`Group.channels` と `Group.audio` に追記
- `SoraTests/DummyAudioDeviceTests.swift` — 新規追加（単体テスト）
- `CHANGES.md` — 変更履歴に以下を追記:
  - [ADD] Configuration にダミー音声の設定を追加する
    - `dummyAudioEnabled` が `true` の場合、物理マイクの代わりにダミー音声（正弦波/無音）を生成して送信する
    - `RTCAudioDevice` プロトコルを実装したカスタム音声デバイスで PCM データを注入する
    - 遠隔音声の再生は AUAudioUnit（RemoteIO）経由で引き続き動作する
    - @voluntas

## 完了条件

- [ ] `DummyAudioDevice` が `RTCAudioDevice` プロトコルの全必須プロパティ/メソッドを実装し、設計方針のテーブルに従った値を返すこと
- [ ] `deliverRecordedData` ブロックを通じて PCM データが注入され、受信側で 440Hz 正弦波が聞こえること
- [ ] AUAudioUnit 経由での遠隔音声の再生が動作し、`sendrecv` モードで双方向の音声通信が可能であること
- [ ] `.silence` と `.sineWave(frequency:)` の両方の `DummyAudioContent` が正しく動作すること
- [ ] シミュレーター上で `dummyAudioEnabled = true` を設定した Sora 接続が成功し、音声トラックが生成されること
- [ ] `dummyAudioEnabled == false`（デフォルト）の場合、既存のマイク入力・再生に影響がないこと
- [ ] 切断時に `DummyAudioDevice` が適切に停止され（録音タイマー + AUAudioUnit）、再接続時にも正しく動作すること
- [ ] 単体テストが実装され、すべて成功すること
- [ ] `CHANGES.md` に変更履歴が追記されていること
