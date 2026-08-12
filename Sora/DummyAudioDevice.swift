import AVFoundation
import AudioToolbox
import Foundation
import WebRTC

/// ダミー音声を生成・注入する RTCAudioDevice 実装
///
/// 物理マイクの代わりに DispatchSourceTimer で PCM データを生成して
/// delegate.deliverRecordedData で ADM に注入する。
/// 遠隔音声の再生は AUAudioUnit (RemoteIO) の outputProvider 経由で
/// delegate.getPlayoutData を呼び出す。
///
/// PCM データの生成 (波形の内容) は pcmGenerator として外部から注入する。
/// 波形のロジック (正弦波等) はテスト・デモの用途に依存するため、SDK 側では持たない。
///
/// delegate が未設定 (nil) の場合のデフォルト値は、サンプルレート 48000 Hz、
/// IO バッファ期間 0.02 秒 (20ms) である。
/// 接続時は delegate が選択する値 (preferredInputSampleRate /
/// preferredInputIOBufferDuration 等) を使用する。
final class DummyAudioDevice: NSObject, RTCAudioDevice {

  /// PCM データ生成処理。
  /// 第 1 引数: データ書き込み先、第 2 引数: フレーム数、第 3 引数: サンプルレート
  private let pcmGenerator:
    (_ data: UnsafeMutableRawPointer, _ frameCount: Int, _ sampleRate: Double)
      -> Void

  // 録音タイマーキュー (recordingQueue) と ADM スレッドの間で共有する状態を保護するロック。
  // deliverPCMData は recordingQueue から呼ばれる一方、
  // startRecording / stopRecording / setHardMute / terminateDevice は ADM スレッドから呼ばれる。
  // delegate / _isRecording / isHardMuted の読み書きはこのロックで直列化する。
  private let stateLock = NSLock()

  private weak var delegate: RTCAudioDeviceDelegate?

  /// delegate をロック付きで取得する。
  /// 弱参照のため、取得した時点で強参照としてローカルに保持する必要がある
  private func lockedDelegate() -> RTCAudioDeviceDelegate? {
    stateLock.lock()
    defer { stateLock.unlock() }
    return delegate
  }

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

  // ハードミュート状態。initialMicrophoneEnabled = false の場合は初期状態でミュートする
  // (Configuration.initialMicrophoneEnabled の契約をダミー音声経路でも守る)
  private(set) var isHardMuted: Bool

  /// 初期化する
  /// - Parameter initialMicrophoneEnabled: 初期状態でハードミュートするかどうか
  /// - Parameter pcmGenerator: PCM データ生成処理 (波形の内容を決める)
  init(
    initialMicrophoneEnabled: Bool,
    pcmGenerator:
      @escaping (
        _ data: UnsafeMutableRawPointer, _ frameCount: Int, _ sampleRate: Double
      ) -> Void
  ) {
    self.pcmGenerator = pcmGenerator
    self.isHardMuted = !initialMicrophoneEnabled
    super.init()
  }

  // 異常経路で terminateDevice が呼ばれずに解放された場合に備える
  deinit {
    recordingTimer?.cancel()
  }

  // MARK: - RTCAudioDevice プロパティ

  var deviceInputSampleRate: Double {
    lockedDelegate()?.preferredInputSampleRate ?? 48000
  }

  var inputIOBufferDuration: TimeInterval {
    lockedDelegate()?.preferredInputIOBufferDuration ?? 0.02
  }

  var inputNumberOfChannels: Int { 1 }

  var inputLatency: TimeInterval { 0 }

  var deviceOutputSampleRate: Double {
    lockedDelegate()?.preferredOutputSampleRate ?? 48000
  }

  var outputIOBufferDuration: TimeInterval {
    lockedDelegate()?.preferredOutputIOBufferDuration ?? 0.02
  }

  var outputNumberOfChannels: Int { 1 }

  var outputLatency: TimeInterval { 0 }

  var isInitialized: Bool { _isInitialized }
  var isPlayoutInitialized: Bool { _isPlayoutInitialized }
  var isPlaying: Bool { _isPlaying }
  var isRecordingInitialized: Bool { _isRecordingInitialized }
  var isRecording: Bool { _isRecording }

  // MARK: - RTCAudioDevice メソッド

  func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
    stateLock.lock()
    self.delegate = delegate
    stateLock.unlock()

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

  func terminateDevice() -> Bool {
    let stop: () -> Void = { [weak self] in
      guard let self else { return }
      self.recordingTimer?.cancel()
      self.recordingTimer = nil
      self.stateLock.lock()
      self._isRecording = false
      self._isRecordingInitialized = false
      self.stateLock.unlock()
      self.audioUnit?.stopHardware()
      self.audioUnit = nil
      self._isPlaying = false
      self._isPlayoutInitialized = false
    }
    if let delegate = lockedDelegate() {
      delegate.dispatchSync(stop)
    } else {
      stop()
    }
    stateLock.lock()
    self.delegate = nil
    stateLock.unlock()
    _isInitialized = false
    return true
  }

  // MARK: - 再生 (Playout)

  func initializePlayout() -> Bool {
    guard let delegate = lockedDelegate() else { return false }

    let desc = AudioComponentDescription(
      componentType: kAudioUnitType_Output,
      componentSubType: kAudioUnitSubType_RemoteIO,
      componentManufacturer: kAudioUnitManufacturer_Apple,
      componentFlags: 0,
      componentFlagsMask: 0)

    guard let au = try? AUAudioUnit(componentDescription: desc) else {
      Logger.warn(
        type: .dummyAudioDevice,
        message: "failed to create AUAudioUnit")
      return false
    }
    au.isOutputEnabled = true
    au.isInputEnabled = false  // 録音は別経路（タイマー）のため入力不要
    au.maximumFramesToRender = 1024

    // outputProvider が提供するデータのフォーマットは inputBus 0 のフォーマットに従う。
    // ADM の OnGetPlayoutData は AudioBufferList が Int16 かつ 1〜2 チャネルであることを要求するため、
    // RemoteIO のデフォルト (Float32) ではなく Int16 フォーマットを inputBusses[0] に明示設定する
    let format = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: delegate.preferredOutputSampleRate,
      channels: 1,
      interleaved: true)
    guard let format else { return false }
    do {
      try au.inputBusses[0].setFormat(format)
    } catch {
      Logger.warn(
        type: .dummyAudioDevice,
        message: "failed to set output format: \(error.localizedDescription)")
      return false
    }

    let getPlayoutData = delegate.getPlayoutData
    au.outputProvider = {
      (actionFlags, timestamp, frameCount, inputBusNumber, outputData) -> AUAudioUnitStatus in
      return getPlayoutData(actionFlags, timestamp, inputBusNumber, frameCount, outputData)
    }

    do {
      try au.allocateRenderResources()
    } catch {
      Logger.warn(
        type: .dummyAudioDevice,
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
      Logger.warn(
        type: .dummyAudioDevice,
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

  // MARK: - 録音 (Recording)

  func initializeRecording() -> Bool {
    _isRecordingInitialized = true
    return true
  }

  func startRecording() -> Bool {
    guard let delegate = lockedDelegate() else { return false }

    // 既存タイマーが残っている場合は先にキャンセルする。
    // Offer SDP 作成のたびに startRecording が呼ばれ得るため、再入は安全でなければならない
    recordingTimer?.cancel()

    stateLock.lock()
    _isRecording = true
    stateLock.unlock()

    let timer = DispatchSource.makeTimerSource(queue: recordingQueue)
    let interval = delegate.preferredInputIOBufferDuration
    let intervalNs = Int(interval * Double(NSEC_PER_SEC))

    // ADM 側が recording フラグを立てる前に届いた最初のフレームが破棄されるため、
    // 1 インターバル分遅らせて開始する
    timer.schedule(
      deadline: .now() + .nanoseconds(intervalNs),
      repeating: .nanoseconds(intervalNs))
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
    stateLock.lock()
    _isRecording = false
    stateLock.unlock()
    return true
  }

  /// ハードミュートを有効化/無効化する
  /// - Parameter mute: `true` でミュート有効化、`false` でミュート無効化
  /// - Returns: 成功した場合は `true`
  func setHardMute(_ mute: Bool) -> Bool {
    let update: () -> Void = { [weak self] in
      guard let self else { return }
      self.stateLock.lock()
      self.isHardMuted = mute
      self.stateLock.unlock()
    }
    if let delegate = lockedDelegate() {
      delegate.dispatchSync(update)
    } else {
      update()
    }
    return true
  }

  private func deliverPCMData() {
    // 共有状態をロックで直列化して読み取る。
    // delegate は弱参照のため、ローカル変数にコピーして強参照にすることで、
    // deliverRecordedData 呼び出し中に解放されないようにする
    stateLock.lock()
    let delegate = self.delegate
    let isRecording = _isRecording
    let isHardMuted = self.isHardMuted
    stateLock.unlock()

    guard let delegate, isRecording else { return }

    // ハードミュート中は録音データを送信しない
    // (Configuration.initialMicrophoneEnabled = false の契約と setAudioHardMute に対応する)
    if isHardMuted {
      return
    }

    let sampleRate = delegate.preferredInputSampleRate
    // ADM 側と同じ四捨五入でフレーム数を算出する (objc_audio_device.mm に合わせる)
    let frameCount = UInt32((sampleRate * delegate.preferredInputIOBufferDuration) + 0.5)
    // サンプルレート・IO バッファ期間が異常値の場合に備える
    guard frameCount > 0 else {
      Logger.warn(
        type: .dummyAudioDevice,
        message: "invalid frame count: \(frameCount)")
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
      Logger.warn(
        type: .dummyAudioDevice,
        message: "failed to allocate PCM data")
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
  /// 波形の生成は pcmGenerator (外部注入) に委譲する。
  func fillPCMData(data: UnsafeMutableRawPointer, frameCount: Int, sampleRate: Double = 48000) {
    pcmGenerator(data, frameCount, sampleRate)
  }
}
