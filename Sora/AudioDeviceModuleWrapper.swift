import Foundation
import WebRTC

/// RTCAudioDeviceModule の機能をラップするクラス
internal final class AudioDeviceModuleWrapper {
  private let audioDeviceModule: RTCAudioDeviceModule
  // ハードミュート処理を直列化するためのキュー
  private let queue = DispatchQueue(label: "jp.shiguredo.sora.audio.device.wrapper")
  // 現在のハードミュート状態
  private var isHardMuted: Bool = false

  // 音声バイパス処理の希望状態
  // 実際のバイパス状態を取得する場合は isAudioBypassEnabled を利用します。
  private var desiredAudioBypassEnabled: Bool = false

  init(audioDeviceModule: RTCAudioDeviceModule) {
    self.audioDeviceModule = audioDeviceModule
  }

  /// 音声のハードミュート有効化/無効化します
  /// - Parameter mute: `true` でミュート有効化、`false` でミュート無効化
  /// - Returns: 成功した場合は `true`、失敗した場合は `false` を返します
  func setAudioHardMute(_ mute: Bool) -> Bool {
    queue.sync {
      guard isHardMuted != mute else {
        return true
      }

      let internalResult = mute ? pauseRecordingInternal() : resumeRecordingInternal()
      let message = "setAudioHardMute via RTCAudioDeviceModule mute=\(mute)"
      let result = internalResult == 0
      if result {
        isHardMuted = mute
        if !applyAudioBypass() {
          Logger.warn(
            type: .mediaChannel,
            message: "setAudioHardMute succeeded but failed to re-apply audio bypass")
        }
        Logger.debug(type: .mediaChannel, message: message)
        return true
      } else {
        Logger.error(type: .mediaChannel, message: "\(message) failed")
        return false
      }
    }
  }

  /// 音声バイパス処理の有効化/無効化を設定します
  /// - Parameter enabled: `true` で有効化、`false` で無効化
  /// - Returns: 成功した場合は `true`、失敗した場合は `false` を返します
  func setAudioBypass(_ enabled: Bool) -> Bool {
    queue.sync {
      desiredAudioBypassEnabled = enabled
      return applyAudioBypass()
    }
  }

  /// 保持している音声バイパス設定を再適用します
  /// - Returns: 成功した場合は `true`、失敗した場合は `false` を返します
  func applyAudioBypassIfNeeded() -> Bool {
    queue.sync {
      applyAudioBypass()
    }
  }

  /// 音声バイパス処理の実状態を取得します
  /// - Returns: 有効な場合は `true`、無効な場合は `false` を返します
  ///   AudioUnit が未初期化の場合も `false` を返します
  func isAudioBypassEnabled() -> Bool {
    queue.sync {
      audioDeviceModule.isBypassVoiceProcessingEnabled()
    }
  }

  @available(*, deprecated, message: "isAudioBypassEnabled を利用してください。")
  func isBypassVoiceProcessingEnabled() -> Bool {
    isAudioBypassEnabled()
  }

  private func pauseRecordingInternal() -> Int32 {
    Int32(audioDeviceModule.pauseRecording())
  }

  private func resumeRecordingInternal() -> Int32 {
    Int32(audioDeviceModule.resumeRecording())
  }

  private func applyAudioBypass() -> Bool {
    let result = Int32(audioDeviceModule.setBypassVoiceProcessing(desiredAudioBypassEnabled))
    if result == 0 {
      Logger.debug(
        type: .mediaChannel,
        message: "setAudioBypass enabled=\(desiredAudioBypassEnabled)")
      return true
    }

    Logger.error(
      type: .mediaChannel,
      message:
        "setAudioBypass enabled=\(desiredAudioBypassEnabled) failed result=\(result)")
    return false
  }
}
