import Foundation
import WebRTC

/// WebRTC の imported enum を SDK が扱う文字列へ変換する formatter です。
///
/// SDK のログ、`SoraError.messagingError(reason:)` の reason、公開 API の
/// `RTCRtpParameters.description` へ渡す文字列をここで作ります。
///
/// imported type へ protocol conformance を追加しない理由:
/// 別 module の型を別 module の protocol に準拠させると retroactive conformance の
/// warning (SE-0364) が出て、将来 WebRTC 側が同じ準拠を追加した場合に衝突します。
/// そのため文字列化は SDK 側の関数として持ちます。
enum WebRTCEnumDescription {
  /// `RTCSignalingState` を文字列化します。
  static func signalingState(_ value: RTCSignalingState) -> String {
    switch value {
    case .stable: "stable"
    case .haveLocalOffer: "haveLocalOffer"
    case .haveLocalPrAnswer: "haveLocalPrAnswer"
    case .haveRemoteOffer: "haveRemoteOffer"
    case .haveRemotePrAnswer: "haveRemotePrAnswer"
    case .closed: "closed"
    @unknown default: "unknown(\(value.rawValue))"
    }
  }

  /// `RTCIceConnectionState` を文字列化します。
  ///
  /// `.count` は状態ではなく `RTCIceConnectionStateCount` sentinel です。
  static func iceConnectionState(_ value: RTCIceConnectionState) -> String {
    switch value {
    case .new: "new"
    case .checking: "checking"
    case .connected: "connected"
    case .completed: "completed"
    case .failed: "failed"
    case .disconnected: "disconnected"
    case .closed: "closed"
    case .count: "count"
    @unknown default: "unknown(\(value.rawValue))"
    }
  }

  /// `RTCIceGatheringState` を文字列化します。
  static func iceGatheringState(_ value: RTCIceGatheringState) -> String {
    switch value {
    case .new: "new"
    case .gathering: "gathering"
    case .complete: "complete"
    @unknown default: "unknown(\(value.rawValue))"
    }
  }

  /// `RTCDataChannelState` を文字列化します。
  static func dataChannelState(_ value: RTCDataChannelState) -> String {
    switch value {
    case .connecting: "connecting"
    case .open: "open"
    case .closing: "closing"
    case .closed: "closed"
    @unknown default: "unknown(\(value.rawValue))"
    }
  }

  /// `RTCRtpEncodingParameters.networkPriority` (`RTCPriority`) を文字列化します。
  static func priority(_ value: RTCPriority) -> String {
    switch value {
    case .veryLow: "very-low"
    case .low: "low"
    case .medium: "medium"
    case .high: "high"
    @unknown default: "unknown(\(value.rawValue))"
    }
  }

  /// `RTCRtpParameters.degradationPreference` の raw value を文字列化します。
  ///
  /// `RTCRtpParameters.degradationPreference` は `NSNumber?` のため、enum ではなく raw value を
  /// 受け取ります (`Int` への変換は呼び出し側で行います)。nil (未設定) は `"-"` を返します。
  /// nil を先に束縛しないと `unknown(Optional(99))` のような Optional の補間になります。
  ///
  /// 値 0 の正式名は `RTCDegradationPreferenceMaintainFramerateAndResolution` で、
  /// `RTCDegradationPreferenceDisabled` は削除予定の別名です
  /// (`RTCRtpParameters.h` の `TODO(webrtc:450044904)`)。同じ raw value の case が 2 つある
  /// imported enum の switch は先に書いた case だけが一致して片方が到達不能になるため raw value で
  /// 判定し、既存のログ文字列との互換のため値 0 は `"disabled"` を返します。
  static func degradationPreference(rawValue: Int?) -> String {
    guard let rawValue else {
      return "-"
    }
    return switch rawValue {
    case RTCDegradationPreference.maintainFramerateAndResolution.rawValue: "disabled"
    case RTCDegradationPreference.maintainFramerate.rawValue: "maintain-framerate"
    case RTCDegradationPreference.maintainResolution.rawValue: "maintain-resolution"
    case RTCDegradationPreference.balanced.rawValue: "balanced"
    default: "unknown(\(rawValue))"
    }
  }
}

/// :nodoc:
extension RTCSessionDescription {
  public var sdpDescription: String {
    let lines = sdp.components(separatedBy: .newlines)
      .filter { line in
        !line.isEmpty
      }
    return lines.joined(separator: "\n")
  }
}
