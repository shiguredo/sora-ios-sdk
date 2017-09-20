import UIKit

class ConfigurationMainViewController: UITableViewController {
    
    enum State {
        case connected
        case connecting
        case disconnected
    }
    
    @IBOutlet weak var roleCell: UITableViewCell!
    @IBOutlet weak var roleLabel: UILabel!
    @IBOutlet weak var enableVideoLabel: UILabel!
    @IBOutlet weak var videoCodecLabel: UILabel!
    @IBOutlet weak var videoCodecCell: UITableViewCell!
    @IBOutlet weak var bitRateLabel: UILabel!
    @IBOutlet weak var bitRateCell: UITableViewCell!
    @IBOutlet weak var enableAudioLabel: UILabel!
    @IBOutlet weak var audioCodecLabel: UILabel!
    @IBOutlet weak var audioCodecCell: UITableViewCell!
    
    @IBOutlet weak var enableWebSocketSSLSwitch: UISwitch!
    @IBOutlet weak var hostTextField: UITextField!
    @IBOutlet weak var portTextField: UITextField!
    @IBOutlet weak var signalingPathTextField: UITextField!
    @IBOutlet weak var channelIdTextField: UITextField!
    @IBOutlet weak var roleValueLabel: UILabel!
    @IBOutlet weak var enableSnapshotSwitch: UISwitch!
    @IBOutlet weak var enableVideoSwitch: UISwitch!
    @IBOutlet weak var videoCodecValueLabel: UILabel!
    @IBOutlet weak var bitRateValueLabel: UILabel!
    @IBOutlet weak var enableAudioSwitch: UISwitch!
    @IBOutlet weak var audioCodecValueLabel: UILabel!
    @IBOutlet weak var webRTCVersionValueLabel: UILabel!
    @IBOutlet weak var webRTCRevisionValueLabel: UILabel!
    
    @IBOutlet weak var tapGestureRecognizer: UITapGestureRecognizer!
    
    public var configurationViewController: ConfigurationViewController? {
        get {
            return (navigationController as! ConfigurationNavigationController?)?
                .configurationViewController
        }
    }

    // MARK: View Controller
    
    override open func viewDidLoad() {
        super.viewDidLoad()
    }
    
    func enable(label: UILabel, isEnabled: Bool) {
        label.isEnabled = isEnabled
        if isEnabled {
            label.textColor = UIColor.black
        } else {
            label.textColor = UIColor.lightGray
        }
    }
    
    func updateControls() {
        hostTextField.text = configurationViewController?.host
        portTextField.text = configurationViewController?.port?.description
        signalingPathTextField.text = configurationViewController?.signalingPath
        channelIdTextField.text = configurationViewController?.channelId
        
        if let role = configurationViewController?.role {
            switch role {
            case .publisher:
                roleValueLabel.text = "Publisher"
            case .subscriber:
                roleValueLabel.text = "Subscriber"
            case .group:
                roleValueLabel.text = "Group"
            }
        }
        
        // snapshot
        let snapshotEnabled = configurationViewController?.snapshotEnabled ?? false
        enableSnapshotSwitch.setOn(snapshotEnabled, animated: true)
        enableVideoLabel.setTextOn(!snapshotEnabled)
        enableVideoSwitch.isEnabled = !snapshotEnabled
        videoCodecLabel.setTextOn(!snapshotEnabled)
        videoCodecCell.isUserInteractionEnabled = !snapshotEnabled
        bitRateLabel.setTextOn(!snapshotEnabled)
        bitRateCell.isUserInteractionEnabled = !snapshotEnabled
        enableAudioLabel.setTextOn(!snapshotEnabled)
        enableAudioSwitch.isEnabled = !snapshotEnabled
        audioCodecLabel.setTextOn(!snapshotEnabled)
        audioCodecCell.isUserInteractionEnabled = !snapshotEnabled

        switch configurationViewController?.videoCodec {
        case .default?, nil:
            videoCodecValueLabel.text = "Default"
        case .vp8?:
            videoCodecValueLabel.text = "VP8"
        case .vp9?:
            videoCodecValueLabel.text = "VP9"
        case .h264?:
            videoCodecValueLabel.text = "H.264"
        }
        
        bitRateValueLabel.text = configurationViewController?
            .videoBitRate?.description ?? "Default"
        
        switch configurationViewController?.audioCodec {
        case .default?, nil:
            audioCodecValueLabel.text = "Default"
        case .opus?:
            audioCodecValueLabel.text = "Opus"
        case .pcmu?:
            audioCodecValueLabel.text = "PCMU"
        }
        
        // build info
        webRTCVersionValueLabel.text = Sora.shared.webRTCInfo?.version ?? "Unknown"
        webRTCRevisionValueLabel.text = Sora.shared.webRTCInfo?.shortRevision ?? "Unknown"
    }
    
    func applicationDidEnterBackground(_ notification: Notification) {
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateControls()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }
    
    override open func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    // MARK: アクション

    @IBAction func back(_ sender: AnyObject) {
        dismiss(animated: true)
    }
    
    @IBAction func snapshotEnabledValueChanged(_ sender: AnyObject) {
        configurationViewController?.snapshotEnabled = enableSnapshotSwitch.isOn
        updateControls()
    }
    
    // MARK: テキストフィールドの編集
    
    @IBAction func hostTextFieldEditingDidEndOnExit(_ sender: AnyObject) {
        configurationViewController?.host = hostTextField.text
    }
    
    @IBAction func portTextFieldEditingDidEndOnExit(_ sender: AnyObject) {
        if let text = portTextField.text {
            if let port = Int(text) {
                configurationViewController?.port = port
            } else {
                portTextField.text = nil
            }
        }
    }
    
    @IBAction func signalingPathTextFieldEditingDidEndOnExit(_ sender: AnyObject) {
        configurationViewController?.signalingPath = signalingPathTextField.text
    }

    @IBAction func channelIdTextFieldEditingDidEndOnExit(_ sender: AnyObject) {
        configurationViewController?.channelId = channelIdTextField.text
    }
    
    @IBAction func handleTap(_ sender: UITapGestureRecognizer) {
        if sender.state == .ended {
            view.endEditing(true)
        }
    }
    
}
