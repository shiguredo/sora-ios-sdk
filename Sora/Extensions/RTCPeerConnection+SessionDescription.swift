import Foundation
import WebRTC

extension RTCPeerConnection {
    
    func createAnswer(forOffer offer: String,
                      constraints: RTCMediaConstraints,
                      handler: @escaping (String?, Error?) -> Void) {
        Log.debug(type: .nativePeerChannel, message: "try create answer")
        Log.debug(type: .nativePeerChannel, message: offer)
        
        Log.debug(type: .nativePeerChannel, message: "try setting remote description")
        let offer = RTCSessionDescription(type: .offer, sdp: offer)
        setRemoteDescription(offer) { error in
            guard error == nil else {
                Log.debug(type: .nativePeerChannel,
                          message: "failed setting remote description: (\(error!.localizedDescription)")
                handler(nil, error)
                return
            }
            Log.debug(type: .nativePeerChannel, message: "did set remote description")
            Log.debug(type: .nativePeerChannel, message: "\(offer.sdpDescription)")
            
            Log.debug(type: .nativePeerChannel, message: "try creating native answer")
            self.answer(for: constraints) { answer, error in
                guard error == nil else {
                    Log.debug(type: .nativePeerChannel,
                              message: "failed creating native answer (\(error!.localizedDescription)")
                    handler(nil, error)
                    return
                }
                Log.debug(type: .nativePeerChannel, message: "did create answer")
                
                Log.debug(type: .nativePeerChannel, message: "try setting local description")
                self.setLocalDescription(answer!) { error in
                    guard error == nil else {
                        Log.debug(type: .nativePeerChannel,
                                  message: "failed setting local description")
                        handler(nil, error)
                        return
                    }
                    Log.debug(type: .nativePeerChannel,
                              message: "did set local description")
                    Log.debug(type: .nativePeerChannel,
                              message: "\(answer!.sdpDescription)")
                    Log.debug(type: .nativePeerChannel,
                              message: "did create answer")
                    handler(answer!.sdp, nil)
                }
            }
        }
    }
    
}
