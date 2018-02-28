import UIKit

class ConfigurationMainViewController: UITableViewController,
    ConfigurationViewControllable {
    
    enum State {
        case connected
        case connecting
        case disconnected
    }
    
    @IBOutlet weak var enableWebSocketSSLLabel: UILabel!
    @IBOutlet weak var hostLabel: UILabel!
    @IBOutlet weak var portLabel: UILabel!
    @IBOutlet weak var signalingPathLabel: UILabel!
    @IBOutlet weak var channelIdLabel: UILabel!
    @IBOutlet weak var roleCell: UITableViewCell!
    @IBOutlet weak var roleLabel: UILabel!
    @IBOutlet weak var maxNumberOfSpeakersLabel: UILabel!
    @IBOutlet weak var enableSnapshotLabel: UILabel!
    @IBOutlet weak var enableVideoLabel: UILabel!
    @IBOutlet weak var videoCodecLabel: UILabel!
    @IBOutlet weak var videoCodecCell: UITableViewCell!
    @IBOutlet weak var bitRateLabel: UILabel!
    @IBOutlet weak var bitRateCell: UITableViewCell!
    @IBOutlet weak var cameraResolutionLabel: UILabel!
    @IBOutlet weak var cameraResolutionCell: UITableViewCell!
    @IBOutlet weak var cameraFrameRateLabel: UILabel!
    @IBOutlet weak var cameraFrameRateCell: UITableViewCell!
    @IBOutlet weak var enableAudioLabel: UILabel!
    @IBOutlet weak var audioCodecLabel: UILabel!
    @IBOutlet weak var audioCodecCell: UITableViewCell!
    
    @IBOutlet weak var enableWebSocketSSLSwitch: UISwitch!
    @IBOutlet weak var hostTextField: UITextField!
    @IBOutlet weak var portTextField: UITextField!
    @IBOutlet weak var signalingPathTextField: UITextField!
    @IBOutlet weak var channelIdTextField: UITextField!
    @IBOutlet weak var roleValueLabel: UILabel!
    @IBOutlet weak var maxNumberOfSpeakersTextField: UITextField!
    @IBOutlet weak var enableSnapshotSwitch: UISwitch!
    @IBOutlet weak var enableVideoSwitch: UISwitch!
    @IBOutlet weak var videoCodecValueLabel: UILabel!
    @IBOutlet weak var bitRateValueLabel: UILabel!
    @IBOutlet weak var cameraResolutionValueLabel: UILabel!
    @IBOutlet weak var cameraFrameRateTextField: UITextField!
    @IBOutlet weak var enableAudioSwitch: UISwitch!
    @IBOutlet weak var audioCodecValueLabel: UILabel!
    @IBOutlet weak var webRTCVersionValueLabel: UILabel!
    @IBOutlet weak var webRTCRevisionValueLabel: UILabel!
    
    weak var configurationViewController: ConfigurationViewController? {
        didSet {
            updateControls()
            
            configurationViewController?.onLockHandler = onLockOrUnlock
            configurationViewController?.onUnlockHandler = onLockOrUnlock
        }
    }

    func onLockOrUnlock() {
        self.updateControls()
        for vc in self.relationalViewControllers {
            Logger.debug(type: .configurationViewController,
                         message: "update controls: \(vc)")
            vc.viewDidLoad()
            vc.viewWillAppear(true)
            vc.viewDidAppear(true)
        }
    }
    
    // MARK: View Controller
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let copy = UIBarButtonItem(title: "Copy",
                                   style: .plain,
                                   target: self,
                                   action: #selector(copyConfiguration))
        //navigationItem.title = "Log"
        navigationItem.rightBarButtonItems = [copy]
    }

    func encodeAndCopyConfiguration(format: JSONEncoder.OutputFormatting?) {
        let encoder = JSONEncoder()
        if let format = format {
            encoder.outputFormatting = format
        }
        let data = try! encoder.encode(self.configurationViewController!.configuration)
        let repr = String(data: data, encoding: .utf8)!
        UIPasteboard.general.setValue(repr, forPasteboardType: "public.text")
    }
    
    func showCopiedAlert() {
        let alert = UIAlertController(title: "コピーしました",
                                      message: nil,
                                      preferredStyle: .alert)
        self.present(alert, animated: true) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                alert.dismiss(animated: true)
            }
        }
    }
    
    @objc func copyConfiguration() {
        let sheet = UIAlertController(title: nil,
                                      message: nil,
                                      preferredStyle: .actionSheet)
        
        sheet.addAction(UIAlertAction(title: "デフォルトのフォーマット",
                                      style: .default)
        { action in
            self.encodeAndCopyConfiguration(format: nil)
            self.showCopiedAlert()
        })
        
        sheet.addAction(UIAlertAction(title: "Pretty printed",
                                      style: .default)
        { action in
            self.encodeAndCopyConfiguration(format: .prettyPrinted)
            self.showCopiedAlert()
        })
        
        if #available(iOS 11.0, *) {
            sheet.addAction(UIAlertAction(title: "キーをソートする",
                                          style: .default)
            { action in
                self.encodeAndCopyConfiguration(format: .sortedKeys)
                self.showCopiedAlert()
            })
        }
        
        self.present(sheet, animated: true)
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
        Logger.debug(type: .configurationViewController,
                     message: "\(self) update controls")
        
        // unlock configuration
        if !(configurationViewController?.isLocked ?? true) {
            lockControls(false)
        }
        
        enableWebSocketSSLSwitch.setOn(configurationViewController?.webSocketSSLEnabled ?? true,
                                       animated: true)
        hostTextField.text = configurationViewController?.host
        portTextField.text = configurationViewController?.port?.description
        signalingPathTextField.text = configurationViewController?.signalingPath
        channelIdTextField.text = configurationViewController?.channelId
        maxNumberOfSpeakersTextField.text = configurationViewController?
            .maxNumberOfSpeakers?.description
        
        if let role = configurationViewController?.role {
            switch role {
            case .publisher:
                roleValueLabel.text = "パブリッシャー"
            case .subscriber:
                roleValueLabel.text = "サブスクライバー"
            case .group:
                roleValueLabel.text = "グループ (送受信)"
            case .groupSub:
                roleValueLabel.text = "グループ (受信のみ)"
            }
        }
        
        enableVideoSwitch.setOn(configurationViewController?.videoEnabled ?? true,
                                animated: true)
        enableAudioSwitch.setOn(configurationViewController?.audioEnabled ?? true,
                                animated: true)
        
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
            videoCodecValueLabel.text = "未設定"
        case .vp8?:
            videoCodecValueLabel.text = "VP8"
        case .vp9?:
            videoCodecValueLabel.text = "VP9"
        case .h264?:
            videoCodecValueLabel.text = "H.264"
        }
        
        bitRateValueLabel.text = configurationViewController?
            .videoBitRate?.description ?? "未設定"
        
        cameraResolutionValueLabel.text = "320x240"
        if let resolution = configurationViewController?.cameraResolution {
            switch resolution {
            case .qvga240p:
                cameraResolutionValueLabel.text = "320x240"
            case .vga480p:
                cameraResolutionValueLabel.text = "640x480"
            case .hd720p:
                cameraResolutionValueLabel.text = "1280x720"
            case .hd1080p:
                cameraResolutionValueLabel.text = "1920x1080"
            }
        }
        
        cameraFrameRateTextField.text =
            configurationViewController?.cameraFrameRate?.description
        
        switch configurationViewController?.audioCodec {
        case .default?, nil:
            audioCodecValueLabel.text = "未設定"
        case .opus?:
            audioCodecValueLabel.text = "Opus"
        case .pcmu?:
            audioCodecValueLabel.text = "PCMU"
        }
        
        // build info
        webRTCVersionValueLabel.text = Sora.shared.webRTCInfo?.version ?? "不明"
        webRTCRevisionValueLabel.text = Sora.shared.webRTCInfo?.shortRevision ?? "不明"
        
        // lock configuration
        if configurationViewController?.isLocked ?? false {
            lockControls(true)
        }
    }
    
    func lockControls(_ flag: Bool) {
        if flag {
            Logger.debug(type: .configurationViewController,
                         message: "\(self) lock controls")
        } else {
            Logger.debug(type: .configurationViewController,
                         message: "\(self) unlock controls")
        }
        
        enableWebSocketSSLLabel.setTextOn(!flag)
        enableWebSocketSSLSwitch.isUserInteractionEnabled = !flag
        hostLabel.setTextOn(!flag)
        hostTextField.isUserInteractionEnabled = !flag
        portLabel.setTextOn(!flag)
        portTextField.isUserInteractionEnabled = !flag
        signalingPathLabel.setTextOn(!flag)
        signalingPathTextField.isUserInteractionEnabled = !flag
        channelIdLabel.setTextOn(!flag)
        channelIdTextField.isUserInteractionEnabled = !flag
        roleLabel.setTextOn(!flag)
        roleCell.isUserInteractionEnabled = !flag
        maxNumberOfSpeakersLabel.setTextOn(!flag)
        maxNumberOfSpeakersTextField.isUserInteractionEnabled = !flag
        enableVideoLabel.setTextOn(!flag)
        enableVideoSwitch.isUserInteractionEnabled = !flag
        videoCodecLabel.setTextOn(!flag)
        videoCodecCell.isUserInteractionEnabled = !flag
        bitRateLabel.setTextOn(!flag)
        bitRateCell.isUserInteractionEnabled = !flag
        cameraResolutionLabel.setTextOn(!flag)
        cameraResolutionCell.isUserInteractionEnabled = !flag
        cameraFrameRateLabel.setTextOn(!flag)
        cameraFrameRateTextField.isUserInteractionEnabled = !flag
        cameraFrameRateCell.isUserInteractionEnabled = !flag
        enableSnapshotLabel.setTextOn(!flag)
        enableSnapshotSwitch.isUserInteractionEnabled = !flag
        enableAudioLabel.setTextOn(!flag)
        enableAudioSwitch.isUserInteractionEnabled = !flag
        audioCodecLabel.setTextOn(!flag)
        audioCodecCell.isUserInteractionEnabled = !flag
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
    
    var relationalViewControllers: [UIViewController] = []
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        configurationViewController?.set(for: segue)
        if !relationalViewControllers.contains(segue.destination) {
            Logger.debug(type: .configurationViewController,
                         message: "add \(segue.destination) for lock")
            relationalViewControllers.append(segue.destination)
        }
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    // MARK: アクション

    @IBAction func back(_ sender: AnyObject) {
        dismiss(animated: true)
    }
    
    @IBAction func webSocketSSLEnabledValueChanged(_ sender: AnyObject) {
        configurationViewController?.webSocketSSLEnabled = enableWebSocketSSLSwitch.isOn
        updateControls()
    }
    
    @IBAction func videoEnabledValueChanged(_ sender: AnyObject) {
        configurationViewController?.videoEnabled = enableVideoSwitch.isOn
        updateControls()
    }
    
    @IBAction func audioEnabledValueChanged(_ sender: AnyObject) {
        configurationViewController?.audioEnabled = enableAudioSwitch.isOn
        updateControls()
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
                configurationViewController?.port = nil
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
    
    @IBAction func maxNumberOfSpeakersTextFieldEditingDidEndOnExit(_ sender: AnyObject) {
        if let text = maxNumberOfSpeakersTextField.text {
            if let num = Int(text) {
                configurationViewController?.maxNumberOfSpeakers = num
            } else {
                configurationViewController?.maxNumberOfSpeakers = nil
                maxNumberOfSpeakersTextField.text = nil
            }
        }
    }
    
    @IBAction func cameraFrameRateTextFieldEditingDidEndOnExit(_ sender: AnyObject) {
        if let text = cameraFrameRateTextField.text {
            if let value = Int(text) {
                configurationViewController?.cameraFrameRate = value
            } else {
                cameraFrameRateTextField.text = nil
            }
        }
    }
    
    @IBAction func handleTap(_ sender: UITapGestureRecognizer) {
        if sender.state == .ended {
            hostTextFieldEditingDidEndOnExit(sender)
            portTextFieldEditingDidEndOnExit(sender)
            signalingPathTextFieldEditingDidEndOnExit(sender)
            channelIdTextFieldEditingDidEndOnExit(sender)
            maxNumberOfSpeakersTextFieldEditingDidEndOnExit(sender)
            cameraFrameRateTextFieldEditingDidEndOnExit(sender)
            view.endEditing(true)
        }
    }
    
}

