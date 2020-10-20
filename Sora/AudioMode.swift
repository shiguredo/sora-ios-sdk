import Foundation
import AVFoundation

public enum AudioMode {
    
    case `default`(category: AVAudioSession.Category)
    case videoChat(output: AudioOutput)
    case voiceChat(output: AudioOutput)
    
}

public enum AudioOutput {
    
    case `default`
    case speaker
    
    var portOverride: AVAudioSession.PortOverride {
        switch self {
        case .default:
            return .none
        case .speaker:
            return .speaker
        }
    }
    
}
