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

  private func pauseRecordingInternal() -> Int32 {
    Int32(audioDeviceModule.pauseRecording())
  }

  private func resumeRecordingInternal() -> Int32 {
    Int32(audioDeviceModule.resumeRecording())
  }
}
