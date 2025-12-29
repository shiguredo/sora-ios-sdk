import Foundation
import WebRTC

/// RTCAudioDeviceModule の録音ポーズ/再開をラップするクラス
public final class AudioDeviceModuleWrapper {
  private let audioDeviceModule: RTCAudioDeviceModule
  // ハードミュート処理を直列化するためのキュー
  private let queue = DispatchQueue(label: "jp.shiguredo.sora.audio.device.wrapper")
  // 現在のハードミュート状態
  private var isHardMuted: Bool = false

  public init(audioDeviceModule: RTCAudioDeviceModule) {
    self.audioDeviceModule = audioDeviceModule
  }

  /// 音声のハードミュート有効化/無効化します
  /// - Parameter mute: `true` でミュート有効化、`false` でミュート無効化
  /// - Returns: 成功した場合は `true`
  public func setAudioHardMute(_ mute: Bool) -> Bool {
    queue.sync {
      guard isHardMuted != mute else { return true }
      let internalResult = mute ? pauseRecordingInternal() : resumeRecordingInternal()
      let message = "setAudioHardMute via RTCAudioDeviceModule mute=\(mute)"
      let result = internalResult == 0
      if result {
        isHardMuted = mute
        Logger.debug(type: .mediaChannel, message: message)
      } else {
        Logger.error(type: .mediaChannel, message: "\(message) failed")
      }
      return result
    }
  }

  private func pauseRecordingInternal() -> Int32 {
    Int32(audioDeviceModule.pauseRecording())
  }

  private func resumeRecordingInternal() -> Int32 {
    Int32(audioDeviceModule.resumeRecording())
  }
}
