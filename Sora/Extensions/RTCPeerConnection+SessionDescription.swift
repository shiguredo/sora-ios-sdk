import Foundation
import WebRTC

/**
 :nodoc:
 */
extension RTCPeerConnection {
    
    func createAnswer(forOffer offer: String,
                      constraints: RTCMediaConstraints,
                      handler: @escaping (String?, Error?) -> Void) {
        Logger.debug(type: .nativePeerChannel, message: "try create answer")
        Logger.debug(type: .nativePeerChannel, message: offer)
        
        Logger.debug(type: .nativePeerChannel, message: "try setting remote description")
        let offer = RTCSessionDescription(type: .offer, sdp: offer)
        setRemoteDescription(offer) { error in
            guard error == nil else {
                Logger.debug(type: .nativePeerChannel,
                          message: "failed setting remote description: (\(error!.localizedDescription)")
                handler(nil, error)
                return
            }
            Logger.debug(type: .nativePeerChannel, message: "did set remote description")
            Logger.debug(type: .nativePeerChannel, message: "\(offer.sdpDescription)")
            
            Logger.debug(type: .nativePeerChannel, message: "try creating native answer")
            self.answer(for: constraints) { answer, error in
                guard error == nil else {
                    Logger.debug(type: .nativePeerChannel,
                              message: "failed creating native answer (\(error!.localizedDescription)")
                    handler(nil, error)
                    return
                }
                Logger.debug(type: .nativePeerChannel, message: "did create answer")
                
                Logger.debug(type: .nativePeerChannel, message: "try setting local description")
                self.setLocalDescription(answer!) { error in
                    guard error == nil else {
                        Logger.debug(type: .nativePeerChannel,
                                  message: "failed setting local description")
                        handler(nil, error)
                        return
                    }
                    Logger.debug(type: .nativePeerChannel,
                              message: "did set local description")
                    Logger.debug(type: .nativePeerChannel,
                              message: "\(answer!.sdpDescription)")
                    Logger.debug(type: .nativePeerChannel,
                              message: "did create answer")
                    handler(answer!.sdp, nil)
                }
            }
        }
    }
    
}
