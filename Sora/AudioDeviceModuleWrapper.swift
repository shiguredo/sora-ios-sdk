import Foundation
import WebRTC

/// RTCAudioDeviceModule の録音ポーズ/再開をラップするクラス。
public final class AudioDeviceModuleWrapper {
  private let audioDeviceModule: RTCAudioDeviceModule
  // ハードミュート処理を直列化するためのキュー
  private let queue = DispatchQueue(label: "jp.shiguredo.sora.audio.device.wrapper")
  private var isHardMuted: Bool = false

  public init(audioDeviceModule: RTCAudioDeviceModule) {
    self.audioDeviceModule = audioDeviceModule
  }

  /// 音声のハードミュート有効化/無効化します
  /// RTCAudioDeviceModule の pause/resume と RTCAudioSession.isAudioEnabled での切り替えが必要
  /// RTCAudioSession.isAudioEnabled 操作には RTCAudioSession.useManualAudio=true が必要なため
  /// useManualAudio を true に変更します
  /// 
  /// - Parameter mute: `true` で一時停止、`false` で再開
  /// - Returns: 成功した場合は `true`
  public func setAudioHardMute(_ mute: Bool) -> Bool {
    queue.sync {
      if !setAudioHardMuteInternal(mute) {
        return false
      }

      let session = RTCAudioSession.sharedInstance()
      session.lockForConfiguration()
      session.useManualAudio = true
      session.isAudioEnabled = !mute
      session.unlockForConfiguration()

      Logger.debug(
        type: .mediaChannel,
        message: "setAudioHardMute via isAudioEnabled=\(!mute)")

      isHardMuted = mute
      return true
    }
  }

  /// ハードミュート状態を保持している場合にリセットします
  /// RTCAudioSession.useManualAudio/isAudioEnabled もデフォルトの false にリセットします
  ///
  /// NativePeerChannelFactory、RTCAudioSession はシングルトンでのオブジェクト運用により
  /// ハードミュート状態で切断後に再接続時する際、前回の状態が残ってしまうため
  public func resetHardMuteIfNeeded() {
    guard isHardMuted else {
      return
    }
    queue.sync {
      setAudioHardMuteInternal(false)
      let session = RTCAudioSession.sharedInstance()
      session.lockForConfiguration()
      session.useManualAudio = false
      session.isAudioEnabled = false
      session.unlockForConfiguration()
      isHardMuted = false
      Logger.debug(
        type: .mediaChannel,
        message: "Reset audio hard mute and useManualAudio/isAudioEnabled via RTCAudioSession")
    }
  }

  private func setAudioHardMuteInternal(_ mute: Bool) -> Bool {
    let result = mute ? pauseRecordingInternal() : resumeRecordingInternal()
    if result == 0 {
      Logger.debug(
        type: .mediaChannel,
        message: "setAudioHardMute via RTCAudioDeviceModule mute=\(mute)")
        return true
    } else {
      Logger.debug(
        type: .mediaChannel,
        message: "RTCAudioDeviceModule mute=\(mute) failed")
      return false
    }
  }

  private func pauseRecordingInternal() -> Int32 {
    Int32(audioDeviceModule.pauseRecording())
  }

  private func resumeRecordingInternal() -> Int32 {
    Int32(audioDeviceModule.resumeRecording())
  }
}
