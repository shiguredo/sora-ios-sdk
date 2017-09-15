import UIKit

class EventLogViewController: UITableViewController {

    @IBOutlet weak var maxNumberOfLogsTextField: UITextField!
    @IBOutlet weak var enableLoggingSwitch: UISwitch!
    @IBOutlet weak var showURLSwitch: UISwitch!
    @IBOutlet weak var showChannelIdSwitch: UISwitch!
    @IBOutlet weak var showDateAndTimeSwitch: UISwitch!
    @IBOutlet weak var showEventTypeSwitch: UISwitch!
    @IBOutlet weak var showCommentSwitch: UISwitch!
    @IBOutlet weak var filterWebSocketSwitch: UISwitch!
    @IBOutlet weak var filterSignalingSwitch: UISwitch!
    @IBOutlet weak var filterPeerConnectionSwitch: UISwitch!
    @IBOutlet weak var filterConnectionMonitorSwitch: UISwitch!
    @IBOutlet weak var filterMediaPublisherSwitch: UISwitch!
    @IBOutlet weak var filterMediaSubscriberSwitch: UISwitch!
    @IBOutlet weak var filterMediaStreamSwitch: UISwitch!
    @IBOutlet weak var filterVideoRendererSwitch: UISwitch!
    @IBOutlet weak var filterVideoViewSwitch: UISwitch!
    
    @IBOutlet weak var tapGestureRecognizer: UITapGestureRecognizer!

    var connectionController: ConnectionController? {
        get {
            return (navigationController as! ConnectionNavigationController?)?
                .connectionController
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        tapGestureRecognizer.cancelsTouchesInView = false
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.identifier == "EventLogs" {
            if let nextPage = segue.destination as? EventLogTextViewController {
                nextPage.update(settings: self)
            }
        }
    }
    
    @IBAction func handleTap(sender: UITapGestureRecognizer) {
        if sender.state == .ended {
            maxNumberOfLogsTextField.resignFirstResponder()
        }
    }
    
}
