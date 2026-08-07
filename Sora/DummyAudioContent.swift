import Foundation

/// ダミー音声の内容
public enum DummyAudioContent: Sendable {
  /// 無音
  case silence

  /// 指定した周波数の正弦波
  case sineWave(frequency: Double)
}
