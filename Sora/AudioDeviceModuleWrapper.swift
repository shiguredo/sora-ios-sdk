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
  /// - Parameter mute: `true` で一時停止、`false` で再開
  /// - Returns: 成功した場合は `true`
  public func setAudioHardMute(_ mute: Bool) -> Bool {
    queue.sync {
      let result = mute ? pauseRecordingInternal() : resumeRecordingInternal()
      if result == 0 {
        Logger.debug(
          type: .mediaChannel,
          message: "setAudioHardMute via RTCAudioDeviceModule mute=\(mute)")
      } else {
        Logger.debug(
          type: .mediaChannel,
          message: "setAudioHardMute via RTCAudioDeviceModule mute=\(mute) failed")
        return false
      }

      Logger.debug(
        type: .mediaChannel,
        message: "setAudioHardMute via isAudioEnabled=\(!mute)")

      isHardMuted = mute
      return true
    }
  }

  private func pauseRecordingInternal() -> Int32 {
    Int32(audioDeviceModule.pauseRecording())
  }

  private func resumeRecordingInternal() -> Int32 {
    Int32(audioDeviceModule.resumeRecording())
  }
}
