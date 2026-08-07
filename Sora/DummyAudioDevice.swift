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

  // MARK: - RTCAudioDevice メソッド

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

  // MARK: - 再生 (Playout)

  func initializePlayout() -> Bool {
    guard let delegate else { return false }

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
    _isRecording = false
    return true
  }

  private func deliverPCMData() {
    guard let delegate, _isRecording else { return }

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
}
