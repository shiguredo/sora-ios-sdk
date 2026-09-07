import Foundation
import WebRTC

/// RTCAudioDeviceModule の録音ポーズ/再開をラップするクラス
internal final class AudioDeviceModuleWrapper {
  private let audioDeviceModule: RTCAudioDeviceModule
  // ハードミュート処理を直列化するためのキュー
  private let queue = DispatchQueue(label: "jp.shiguredo.sora.audio.device.wrapper")

  init(audioDeviceModule: RTCAudioDeviceModule) {
    self.audioDeviceModule = audioDeviceModule
  }

  /// 音声のハードミュート有効化/無効化します
  /// - Parameter mute: `true` でミュート有効化、`false` でミュート無効化
  /// - Returns: 成功した場合は `true`、失敗した場合は `false` を返します
  func setAudioHardMute(_ mute: Bool) -> Bool {
    queue.sync {
      // 初期ミュートは RTCAudioSession で設定されるため、状態をここで二重管理しない。
      // 同じ要求かどうかの判断も、実際の状態を持つ ADM に任せる。
      let internalResult = mute ? pauseRecordingInternal() : resumeRecordingInternal()
      let message = "setAudioHardMute via RTCAudioDeviceModule mute=\(mute)"
      let result = internalResult == 0
      if result {
        Logger.debug(type: .mediaChannel, message: message)
        return true
      } else {
        Logger.error(type: .mediaChannel, message: "\(message) failed")
        return false
      }
    }
  }

  private func pauseRecordingInternal() -> Int32 {
    Int32(audioDeviceModule.pauseRecording())
  }

  private func resumeRecordingInternal() -> Int32 {
    Int32(audioDeviceModule.resumeRecording())
  }
}
