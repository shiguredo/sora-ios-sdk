import Foundation
import WebRTC

/// RTCAudioDeviceModule の録音ポーズ/再開をラップするクラス
internal final class AudioDeviceModuleWrapper {
  private let audioDeviceModule: RTCAudioDeviceModule
  // ハードミュート処理を直列化するためのキュー
  private let queue = DispatchQueue(label: "jp.shiguredo.sora.audio.device.wrapper")
  // 録音操作の実行先となる factory。m155 以降の ADM は録音の pause/resume を
  // WebRTC の worker スレッド上で実行する契約のため、factory 経由で実行する。
  private let lock = NSLock()
  private var factory: RTCPeerConnectionFactory?

  init(audioDeviceModule: RTCAudioDeviceModule) {
    self.audioDeviceModule = audioDeviceModule
  }

  /// 録音操作の実行先となる factory を設定します。
  ///
  /// ADM の生成直後は factory がまだ存在しないため、factory の生成後に呼び出します。
  /// - Parameter factory: `audioDeviceModule` を受け取った factory
  func bindToFactory(_ factory: RTCPeerConnectionFactory) {
    lock.lock()
    defer { lock.unlock() }
    self.factory = factory
  }

  /// 音声のハードミュート有効化/無効化します
  /// - Parameter mute: `true` でミュート有効化、`false` でミュート無効化
  /// - Returns: 成功した場合は `true`、失敗した場合は `false` を返します
  func setAudioHardMute(_ mute: Bool) -> Bool {
    let result = queue.sync {
      // 初期ミュートは RTCAudioSession で設定されるため、状態をここで二重管理しない。
      // 同じ要求かどうかの判断も、実際の状態を持つ ADM に任せる。
      let internalResult = mute ? pauseRecordingInternal() : resumeRecordingInternal()
      return internalResult == 0
    }

    // ログは queue.sync の外で出す。sync 区間を保持したまま Logger を呼ぶと、利用者の
    // onOutputHandler が同じ queue を使う MediaChannel.setAudioHardMute を呼ぶ経路で deadlock する。
    let message = "setAudioHardMute via RTCAudioDeviceModule mute=\(mute)"
    if result {
      Logger.debug(type: .mediaChannel, message: message)
    } else {
      Logger.error(type: .mediaChannel, message: "\(message) failed")
    }
    return result
  }

  /// 録音操作を WebRTC の worker スレッドで実行し、その戻り値を返します。
  ///
  /// factory が未設定の場合は worker を特定できないため、失敗として扱います。
  private func runOnWorker(_ body: @escaping () -> Int) -> Int32 {
    lock.lock()
    let factory = self.factory
    lock.unlock()
    guard let factory else {
      return Int32(-1)
    }
    // Objective-C の `runOnWorker:` は Swift からは `run(onWorker:)` として見える。
    return Int32(factory.run(onWorker: body))
  }

  private func pauseRecordingInternal() -> Int32 {
    runOnWorker { [audioDeviceModule] in Int(audioDeviceModule.pauseRecording()) }
  }

  private func resumeRecordingInternal() -> Int32 {
    runOnWorker { [audioDeviceModule] in Int(audioDeviceModule.resumeRecording()) }
  }
}
