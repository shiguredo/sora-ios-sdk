import UIKit
import Sora

class ViewController: UIViewController {

    @IBOutlet weak var publisherVideoView: Sora.VideoView!
    @IBOutlet weak var subscriberVideoView: Sora.VideoView!
    @IBOutlet weak var connectButton: UIButton!
    @IBOutlet weak var disconnectButton: UIButton!
    
    var connection: Sora.Connection!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        connectButton.isEnabled = true
        disconnectButton.isEnabled = false
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

    @IBAction func connect(_ sender: AnyObject) {
        connectButton.isEnabled = false
        disconnectButton.isEnabled = false
        
        connection = Sora.Connection(URL:
            URL(string: "ws://192.168.0.2:5000/signaling")!,
                                     mediaChannelId: "soraapp")
        connection.eventLog.debugMode = true
        
        connection.mediaPublisher.connect {
            error in
            if let error = error {
                print(error.localizedDescription)
                self.connectButton.isEnabled = true
                return
            }
            self.connection.mediaSubscriber.connect {
                error in
                if let error = error {
                    print(error.localizedDescription)
                    self.connectButton.isEnabled = true
                    self.connection.mediaPublisher.disconnect {
                        error in
                        if let error = error {
                            print(error.localizedDescription)
                        }
                    }
                    return
                }
                self.disconnectButton.isEnabled = true
                self.connection.mediaPublisher.mainMediaStream!
                    .videoRenderer = self.publisherVideoView
                self.connection.mediaSubscriber.mainMediaStream!
                    .videoRenderer = self.subscriberVideoView
            }
        }
    }
    
    @IBAction func disconnect(_ sender: AnyObject) {
        connection.mediaPublisher.disconnect {
            error in
            if let error = error {
                print(error.localizedDescription)
            }
        }
        connection.mediaSubscriber.disconnect {
            error in
            if let error = error {
                print(error.localizedDescription)
            }
        }
        self.connectButton.isEnabled = true
        self.disconnectButton.isEnabled = false
    }
    
    @IBAction func switchCameraPosition(_ sender: AnyObject) {
        print("switch camera position")
        if disconnectButton.isEnabled {
            connection.mediaPublisher.flipCameraPosition()
        }
    }
    
}

