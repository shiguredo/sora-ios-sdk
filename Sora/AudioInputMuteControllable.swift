import Foundation

/// カスタム音声入力デバイスで音声入力のミュートを制御するためのプロトコルです。
///
/// `Configuration.customAudioDevice` と組み合わせて利用します。
/// 送信音声ありでカスタム音声入力デバイスを利用する場合は、
/// 指定する音声入力デバイスをこのプロトコルにも準拠させてください。
/// 初期マイク状態の適用と `MediaChannel.setAudioHardMute(_:)` の両方で利用します。
/// `setAudioInputMuted(_:)` は接続前や録音開始前に呼ばれる場合があります。
public protocol AudioInputMuteControllable: AnyObject {
  /// 音声入力のミュート有効化 / 無効化を行います。
  /// - Parameter mute: `true` でミュート有効化、 `false` でミュート無効化
  /// - Returns: 成功した場合は `true`、失敗した場合は `false`
  func setAudioInputMuted(_ mute: Bool) -> Bool
}

internal protocol AudioInputMuteController {
  func setAudioInputMuted(_ mute: Bool) -> Bool
}

internal final class AudioInputMuteControllableWrapper: AudioInputMuteController {
  private let audioInputMuteControllable: AudioInputMuteControllable

  init(audioInputMuteControllable: AudioInputMuteControllable) {
    self.audioInputMuteControllable = audioInputMuteControllable
  }

  func setAudioInputMuted(_ mute: Bool) -> Bool {
    audioInputMuteControllable.setAudioInputMuted(mute)
  }
}
