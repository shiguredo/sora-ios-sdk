import Foundation
import WebRTC

/// :nodoc:
extension RTCSignalingState: CustomStringConvertible {
  public var description: String {
    switch self {
    case .stable: return "stable"
    case .haveLocalOffer: return "haveLocalOffer"
    case .haveLocalPrAnswer: return "haveLocalPrAnswer"
    case .haveRemoteOffer: return "haveRemoteOffer"
    case .haveRemotePrAnswer: return "haveRemotePrAnswer"
    case .closed: return "closed"
    @unknown default:
      fatalError("unknown state")
    }
  }
}

/// :nodoc:
extension RTCIceConnectionState: CustomStringConvertible {
  public var description: String {
    switch self {
    case .new: return "new"
    case .checking: return "checking"
    case .connected: return "connected"
    case .completed: return "completed"
    case .failed: return "failed"
    case .disconnected: return "disconnected"
    case .closed: return "closed"
    case .count: return "count"
    @unknown default:
      fatalError("unknown state")
    }
  }
}

/// :nodoc:
extension RTCIceGatheringState: CustomStringConvertible {
  public var description: String {
    switch self {
    case .new: return "new"
    case .gathering: return "gathering"
    case .complete: return "complete"
    @unknown default:
      fatalError("unknown state")
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
