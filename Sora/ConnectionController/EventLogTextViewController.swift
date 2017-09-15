import UIKit

class EventLogTextViewController: UIViewController {
    
    @IBOutlet weak var logTextView: UITextView!
    
    var connectionController: ConnectionController {
        get { return ConnectionController.shared }
    }
    
    weak var settings: EventLogViewController!
    
    override func viewDidLoad() {
        super.viewDidLoad()
    }
    
    func update(settings: EventLogViewController) {
        self.settings = settings
        reload()
    }
    
    func reload() {
        let _ = self.view
        logTextView.text = ""
        if let events = connectionController.connection?.eventLog.events {
            for event in events {
                add(event: event)
            }
        }
    }
    
    func add(event: Event) {
        print("event log mark")
        guard (event.type == .WebSocket &&
            settings.filterWebSocketSwitch.isOn) ||
            (event.type == .Signaling &&
                settings.filterSignalingSwitch.isOn) ||
            (event.type == .PeerConnection &&
                settings.filterPeerConnectionSwitch.isOn) ||
            (event.type == .ConnectionMonitor &&
                settings.filterConnectionMonitorSwitch.isOn) ||
            (event.type == .MediaPublisher &&
                settings.filterMediaPublisherSwitch.isOn) ||
            (event.type == .MediaSubscriber &&
                settings.filterMediaSubscriberSwitch.isOn) ||
            (event.type == .MediaStream &&
                settings.filterMediaStreamSwitch.isOn) ||
            (event.type == .VideoRenderer &&
                settings.filterVideoRendererSwitch.isOn) ||
            (event.type == .VideoView &&
                settings.filterVideoViewSwitch.isOn)
            else {
                return
        }

        var text = logTextView.text ?? ""
        text.append("[")
        if settings.showDateAndTimeSwitch.isOn {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            text.append(formatter.string(from: event.date))
            text.append(" ")
        }
        if settings.showURLSwitch.isOn {
            text.append(event.URL.description)
            text.append(" ")
        }
        if settings.showChannelIdSwitch.isOn {
            text.append("@")
            text.append(event.mediaChannelId)
            text.append(" ")
        }
        if settings.showEventTypeSwitch.isOn {
            text.append("#")
            text.append(event.type.rawValue)
            text.append(" ")
        }
        text.append("] ")
        text.append(event.comment)
        text.append("\n")
        logTextView.text = text
    }
    
    @IBAction func clear(_ sender: AnyObject) {
        logTextView.text = nil
        connectionController.connection?.eventLog.clear()
    }
    
    @IBAction func copyToClipboard(_ sender: AnyObject) {
        UIPasteboard.general.setValue(logTextView.text,
                                      forPasteboardType: "public.text")
    }
    
}
