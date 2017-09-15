import UIKit

struct TextValueTable<Value: Equatable> {
    
    var pairs: [(String, Value)]
    
    func text(value: Value) -> String? {
        for (t, v) in pairs {
            if v == value {
                return t
            }
        }
        return nil
    }
    
    func value(text: String) -> Value? {
        for (t, v) in pairs {
            if t == text {
                return v
            }
        }
        return nil
    }
    
}

class ConnectionViewController: UITableViewController {
    
    enum State {
        case connected
        case connecting
        case disconnected
    }
    
    @IBOutlet weak var connectionStateCell: UITableViewCell!
    @IBOutlet weak var connectionTimeLabel: UILabel!
    @IBOutlet weak var enableMicrophoneLabel: UILabel!
    @IBOutlet weak var eventLogsLabel: UILabel!
    @IBOutlet weak var enableWebSocketSSLLabel: UILabel!
    @IBOutlet weak var hostLabel: UILabel!
    @IBOutlet weak var portLabel: UILabel!
    @IBOutlet weak var signalingPathLabel: UILabel!
    @IBOutlet weak var channelIdLabel: UILabel!
    @IBOutlet weak var roleLabel: UILabel!
    @IBOutlet weak var roleCell: UITableViewCell!
    @IBOutlet weak var enableMultistreamLabel: UILabel!
    @IBOutlet weak var enableVideoLabel: UILabel!
    @IBOutlet weak var videoCodecLabel: UILabel!
    @IBOutlet weak var videoCodecCell: UITableViewCell!
    @IBOutlet weak var bitRateLabel: UILabel!
    @IBOutlet weak var bitRateCell: UITableViewCell!
    @IBOutlet weak var enableSnapshotLabel: UILabel!
    @IBOutlet weak var enableAudioLabel: UILabel!
    @IBOutlet weak var audioCodecLabel: UILabel!
    @IBOutlet weak var audioCodecCell: UITableViewCell!
    @IBOutlet weak var autofocusLabel: UILabel!
    @IBOutlet weak var WebRTCVersionLabel: UILabel!
    @IBOutlet weak var WebRTCRevisionLabel: UILabel!
    
    @IBOutlet weak var connectionTimeValueLabel: UILabel!
    @IBOutlet weak var enableMicrophoneSwitch: UISwitch!
    @IBOutlet weak var enableWebSocketSSLSwitch: UISwitch!
    @IBOutlet weak var hostTextField: UITextField!
    @IBOutlet weak var portTextField: UITextField!
    @IBOutlet weak var signalingPathTextField: UITextField!
    @IBOutlet weak var channelIdTextField: UITextField!
    @IBOutlet weak var rollValueLabel: UILabel!
    @IBOutlet weak var enableMultistreamSwitch: UISwitch!
    @IBOutlet weak var connectButton: UIButton!
    @IBOutlet weak var enableVideoSwitch: UISwitch!
    @IBOutlet weak var videoCodecValueLabel: UILabel!
    @IBOutlet weak var bitRateValueLabel: UILabel!
    @IBOutlet weak var enableSnapshotSwitch: UISwitch!
    @IBOutlet weak var enableAudioSwitch: UISwitch!
    @IBOutlet weak var audioCodecValueLabel: UILabel!
    @IBOutlet weak var autofocusSwitch: UISwitch!
    @IBOutlet weak var WebRTCVersionValueLabel: UILabel!
    @IBOutlet weak var WebRTCRevisionValueLabel: UILabel!
    
    @IBOutlet weak var tapGestureRecognizer: UITapGestureRecognizer!
    
    weak var touchedField: UITextField?
    
    static let videoCodecTable: TextValueTable<VideoCodec> =
        TextValueTable(pairs: [("Default", .default),
                               ("VP8", .VP8),
                               ("VP9", .VP9),
                               ("H.264", .H264)])
    
    static let bitRateTable: TextValueTable<Int> =
        TextValueTable(pairs: [("100", 100),
                               ("300", 300),
                               ("500", 500),
                               ("800", 800),
                               ("1000", 1000),
                               ("1500", 1500),
                               ("2000", 2000),
                               ("2500", 2500),
                               ("3000", 3000),
                               ("5000", 5000)])
    
    static let audioCodecTable: TextValueTable<AudioCodec> =
        TextValueTable(pairs: [("Default", .default),
                               ("Opus", .Opus),
                               ("PCMU", .PCMU)])
    
    var indicator: UIActivityIndicatorView?
    var eventLog: EventLog?
    
    var state: State = .disconnected {
        didSet {
            DispatchQueue.main.async {
                switch self.state {
                case .connected:
                    self.connectButton.setTitle("Disconnect", for: .normal)
                    self.connectButton.isEnabled = true
                    self.connectionStateCell.accessoryView = nil
                    self.connectionStateCell.accessoryType = .checkmark
                    self.indicator?.stopAnimating()
                    self.enableControls(false)
                    self.connectionTimeLabel.textColor = nil
                    
                case .disconnected:
                    self.connectButton.setTitle("Connect", for: .normal)
                    self.connectButton.isEnabled = true
                    self.connectionStateCell.accessoryView = nil
                    self.connectionStateCell.accessoryType = .none
                    self.indicator?.stopAnimating()
                    self.connectionTimeValueLabel.text = nil
                    self.enableControls(true)
                    self.connectionTimeLabel.textColor = UIColor.lightGray
                    
                case .connecting:
                    self.connectButton.titleLabel!.text = "Connecting..."
                    self.connectButton.setTitle("Connecting...", for: .normal)
                    self.connectButton.isEnabled = false
                    self.indicator?.startAnimating()
                    self.connectionStateCell.accessoryView = self.indicator
                    self.connectionStateCell.accessoryType = .none
                    self.connectionTimeValueLabel.text = nil
                    self.enableControls(false)
                    self.connectionTimeLabel.textColor = UIColor.lightGray
                }
            }
        }
    }
    
    var roles: [ConnectionController.Role] = [] {
        didSet {
            var s: [String] = []
            if roles.contains(.publisher) {
                s.append("Publisher")
            }
            if roles.contains(.subscriber) {
                s.append("Subscriber")
            }
            rollValueLabel.text = s.joined(separator: ",")
        }
    }
    
    var multistreamEnabled: Bool {
        get { return enableMultistreamSwitch.isOn }
        set { enableMultistreamSwitch.setOn(newValue, animated: true) }
    }
    
    var videoEnabled: Bool {
        get { return enableVideoSwitch.isOn }
        set { enableVideoSwitch.setOn(newValue, animated: true) }
    }
    
    var videoCodec: VideoCodec? {
        didSet {
            switch videoCodec {
            case .default?, nil:
                videoCodecValueLabel.text = "Default"
            case .VP8?:
                videoCodecValueLabel.text = "VP8"
            case .VP9?:
                videoCodecValueLabel.text = "VP9"
            case .H264?:
                videoCodecValueLabel.text = "H.264"
            }
        }
    }
    
    var bitRate: Int {
        get { return Int(bitRateValueLabel.text ?? "800")! }
        set { bitRateValueLabel.text = newValue.description }
    }
    
    var snapshotEnabled: Bool {
        get { return enableSnapshotSwitch.isOn }
        
        set {
            enableVideoLabel.isEnabled = !newValue
            enableVideoSwitch.isEnabled = !newValue
            enableSnapshotSwitch.setOn(newValue, animated: true)
            videoCodecLabel.isEnabled = !newValue
            videoCodecCell.isUserInteractionEnabled = !newValue
            enableAudioLabel.isEnabled = !newValue
            enableAudioSwitch.isEnabled = !newValue
        }
    }
    
    var audioEnabled: Bool {
        get { return enableAudioSwitch.isOn }
        set { enableAudioSwitch.setOn(newValue, animated: true) }
    }
    
    var audioCodec: AudioCodec? {
        didSet {
            switch audioCodec {
            case .default?, nil:
                audioCodecValueLabel.text = "Default"
            case .Opus?:
                audioCodecValueLabel.text = "Opus"
            case .PCMU?:
                audioCodecValueLabel.text = "PCMU"
            }
        }
    }
    
    var shared: ConnectionController {
        get { return ConnectionController.shared }
    }
    
    var connection: Connection?
    
    // MARK: View Controller
    
    override open func viewDidLoad() {
        super.viewDidLoad()
        
        // Do any additional setup after loading the view.
        indicator = UIActivityIndicatorView(activityIndicatorStyle: .gray)
        tapGestureRecognizer.cancelsTouchesInView = false
        
        for label: UILabel in [connectButton.titleLabel!] {
            label.font = UIFont.preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
        }

        NotificationCenter.default
            .addObserver(self,
                         selector: #selector(applicationDidEnterBackground(_:)),
                         name: NSNotification.Name.UIApplicationDidEnterBackground,
                         object: nil)
        
        enableWebSocketSSLSwitch.addTarget(shared,
                                           action: ConnectionController.Action.updateWebSocketSSLEnabled,
                                           for: .valueChanged)
        hostTextField.addTarget(shared,
                                action: ConnectionController.Action.updateHost,
                                for: .editingChanged)
        portTextField.addTarget(shared,
                                action: ConnectionController.Action.updatePort,
                                for: .editingChanged)
        signalingPathTextField.addTarget(shared,
                                         action: ConnectionController.Action.updateSignalingPath,
                                         for: .editingChanged)
        channelIdTextField.addTarget(shared,
                                     action: ConnectionController.Action.updateChannelId,
                                     for: .editingChanged)
        enableMultistreamSwitch.addTarget(shared,
                                          action: ConnectionController.Action.updateMultistreamEnabled,
                                          for: .valueChanged)
        enableSnapshotSwitch.addTarget(shared,
                                       action: ConnectionController.Action.updateSnapshotEnabled,
                                       for: .valueChanged)
        enableVideoSwitch.addTarget(shared,
                                    action: ConnectionController.Action.updateVideoEnabled,
                                    for: .valueChanged)
        enableAudioSwitch.addTarget(shared,
                                    action: ConnectionController.Action.updateAudioEnabled,
                                    for: .valueChanged)
        autofocusSwitch.addTarget(shared,
                                  action: ConnectionController.Action.updateAutofocus,
                                  for: .valueChanged)
        
        NotificationCenter.default
            .addObserver(self,
                         selector: #selector(userDefaultsDidLoad(_:)),
                         name: ConnectionController.userDefaultsDidLoadNotificationName,
                         object: shared)
        
        state = .disconnected
        roles = [.publisher, .subscriber]
        videoCodec = .default
        audioCodec = .default
        enableMicrophoneLabel.isEnabled = false
        enableMicrophoneSwitch.setOn(false, animated: false)
        autofocusSwitch.setOn(false, animated: false)
        connectionTimeValueLabel.text = nil
        hostTextField.text = shared.host
        hostTextField.placeholder = "ex) www.example.com"
        portTextField.text = shared.port?.description
        portTextField.placeholder = "ex) 5000"
        signalingPathTextField.text = shared.signalingPath
        signalingPathTextField.placeholder = "ex) signaling"
        channelIdTextField.text = shared.channelId
        channelIdTextField.placeholder = "your channel ID"
        
        updateControls()

        // build info
        if let version = BuildInfo.WebRTCVersion {
            WebRTCVersionValueLabel.text = version
        } else {
            WebRTCVersionValueLabel.text = "Unknown"
        }
        if let revision = BuildInfo.WebRTCShortRevision {
            WebRTCRevisionValueLabel.text = revision
        } else {
            WebRTCRevisionValueLabel.text = "Unknown"
        }
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
    
    // MARK: 設定の保存
    
    func updateControls() {
        enableWebSocketSSLSwitch.setOn(shared.WebSocketSSLEnabled, animated: true)
        hostTextField.text = shared.host
        portTextField.text = shared.port?.description
        signalingPathTextField.text = shared.signalingPath
        channelIdTextField.text = shared.channelId
        
        roles = shared.roles
        enableMultistreamSwitch.setOn(shared.multistreamEnabled, animated: true)
        enableVideoSwitch.setOn(shared.videoEnabled, animated: true)
        if let codec = shared.videoCodec {
            videoCodecValueLabel.text = ConnectionViewController.videoCodecTable.text(value: codec)
        }
        if let bitRate = shared.bitRate {
            bitRateValueLabel.text = bitRate.description
        } else {
            bitRateValueLabel.text = "Default"
        }
        enableSnapshotSwitch.setOn(shared.snapshotEnabled,
                                   animated: true)
        
        enableAudioSwitch.setOn(shared.audioEnabled, animated: true)
        if let codec = shared.audioCodec {
            audioCodecValueLabel.text = ConnectionViewController.audioCodecTable.text(value: codec)
        }
    }
    
    func userDefaultsDidLoad(_ notification: Notification) {
        updateControls()
    }
    
    // MARK: アクション
    
    func enableControls(_ isEnabled: Bool) {
        let labels: [UILabel] = [
            enableWebSocketSSLLabel, hostLabel, portLabel,
            signalingPathLabel, channelIdLabel, roleLabel,
            enableMultistreamLabel,
            enableVideoLabel, videoCodecLabel,
            bitRateLabel, enableSnapshotLabel,
            enableAudioLabel, audioCodecLabel,
            ]
        for label in labels {
            label.isEnabled = isEnabled
        }
        
        
        let fields: [UITextField] = [hostTextField,
                                     portTextField,
                                     signalingPathTextField,
                                     channelIdTextField]
        for field in fields {
            field.isEnabled = isEnabled
        }
        
        let controls: [UIView] = [
            enableWebSocketSSLSwitch, hostTextField, portTextField,
            signalingPathTextField, channelIdTextField, roleCell,
            enableMultistreamSwitch,
            enableVideoSwitch, enableAudioSwitch,
            videoCodecCell, bitRateCell, enableSnapshotSwitch, audioCodecCell]
        for control: UIView in controls {
            control.isUserInteractionEnabled = isEnabled
        }
    }

    @IBAction func back(_ sender: AnyObject) {
        shared.saveToUserDefaults()
        dismiss(animated: true)
    }
    
    var connectingAlertController: UIAlertController!
    
    @IBAction func connectOrDisconnect(_ sender: AnyObject) {
        shared.saveToUserDefaults()
        
        switch state {
        case .connecting:
            assertionFailure("invalid state")
            
        case .connected:
            disconnect()
            
        case .disconnected:
            guard let host = hostTextField.nonEmptyText() else {
                presentSimpleAlert(title: "Error",
                                   message: "Input host URL")
                return
            }
            
            var port: UInt?
            if let text = portTextField.nonEmptyText() {
                if let num = UInt(text) {
                    port = num
                } else {
                    presentSimpleAlert(title: "Error",
                                       message: "Invalid port number")
                    return
                }
            }
            
            let signalingPath = signalingPathTextField.nonEmptyText() ??
                signalingPathTextField.placeholder!
            
            guard let channelId = channelIdTextField.nonEmptyText() else {
                presentSimpleAlert(title: "Error",
                                   message: "Input channel ID")
                return
            }
            
            var portStr: String = ""
            if let port = port {
                portStr = String(format: ":%d", port)
            }
            let URLString = String(format: "%@://%@%@/%@",
                                   enableWebSocketSSLSwitch.isOn ? "wss" : "ws",
                                   host, portStr, signalingPath)
            
            guard let URL = URL(string: URLString) else {
                presentSimpleAlert(title: "Error",
                                   message: "Invalid server URL")
                return
            }
            
            if roles.isEmpty {
                presentSimpleAlert(title: "Error",
                                   message: "Select roles")
                return
            }
            
            connection = Connection(URL: URL, mediaChannelId: channelId)
            shared.connection = connection
            eventLog = connection?.eventLog
            let request = ConnectionController
                .Request(URL: URL,
                         channelId: channelId,
                         roles: roles,
                         multistreamEnabled: multistreamEnabled,
                         videoEnabled: videoEnabled,
                         videoCodec: videoCodec ?? .default,
                         bitRate: bitRate,
                         snapshotEnabled: snapshotEnabled,
                         audioEnabled: audioEnabled,
                         audioCodec: audioCodec ?? .default)
            shared.onRequestHandler?(connection!, request)
            
            connectingAlertController = UIAlertController(
                title: nil,
                message: "Connecting to the server...",
                preferredStyle: .alert)
            let indicator = UIActivityIndicatorView(activityIndicatorStyle: .gray)
            indicator.center = CGPoint(x: 25, y: 30)
            connectingAlertController.view.addSubview(indicator)
            connectingAlertController.addAction(
                UIAlertAction(title: "Cancel", style: .cancel)
                {
                    _ in
                    self.disconnect()
                }
            )
            DispatchQueue.main.async {
                indicator.startAnimating()
                self.present(self.connectingAlertController, animated: true) {}
            }
            
            state = .connecting
            if roles.contains(.publisher) {
                self.connectPublisher()
            } else if roles.contains(.subscriber) {
                self.connectSubscriber()
            } else {
                assertionFailure("roles must not be empty")
            }
        }
    }
    
    func connectPublisher() {
        setMediaConnectionSettings(connection!.mediaPublisher)
        connection!.mediaPublisher.connect {
            error in
            DispatchQueue.main.async {
                if let error = error {
                    self.failConnection(error: error)
                    return
                }
                
                self.enableMicrophoneLabel.isEnabled = true
                self.enableMicrophoneSwitch.isEnabled = true
                self.enableMicrophoneSwitch.setOn(true, animated: true)
                
                if self.roles.contains(.subscriber) {
                    self.connectSubscriber()
                } else {
                    self.finishConnection(self.connection!.mediaPublisher)
                }
            }
        }
    }
    
    func connectSubscriber() {
        setMediaConnectionSettings(connection!.mediaSubscriber)
        connection!.mediaSubscriber.connect {
            error in
            DispatchQueue.main.async {
                if let error = error {
                    self.failConnection(error: error)
                    return
                }
                self.finishConnection(self.connection!.mediaSubscriber)
            }
        }
    }
    
    
    func disconnect() {
        if let conn = connection {
            if conn.mediaPublisher.isAvailable {
                conn.mediaPublisher.disconnect { _ in () }
            }
            if conn.mediaSubscriber.isAvailable {
                conn.mediaSubscriber.disconnect { _ in () }
            }
        }
        state = .disconnected
        connectingAlertController = nil
        enableMicrophoneLabel.isEnabled = false
        enableMicrophoneSwitch.isEnabled = false
        enableMicrophoneSwitch.isUserInteractionEnabled = true
        enableMicrophoneSwitch.setOn(false, animated: true)
    }

    func setMediaConnectionSettings(_ mediaConn: MediaConnection) {
        mediaConn.multistreamEnabled = multistreamEnabled
        mediaConn.mediaOption.videoEnabled = videoEnabled
        if let codec = shared.videoCodec {
            mediaConn.mediaOption.videoCodec = codec
        }
        mediaConn.mediaOption.bitRate = bitRate
        mediaConn.mediaOption.snapshotEnabled = snapshotEnabled
        mediaConn.mediaOption.audioEnabled = audioEnabled
        if let codec = shared.audioCodec {
            mediaConn.mediaOption.audioCodec = codec
        }
        
    }
    
    func failConnection(error: ConnectionError) {
        let title = "Connection Error"
        let message = error.description
        if let alert = connectingAlertController {
            alert.dismiss(animated: true) {
                self.finishFailure(title: title, message: message, error: error)
            }
        } else {
            finishFailure(title: title, message: message, error: error)
        }
    }
    
    func finishFailure(title: String, message: String, error: ConnectionError) {
        presentSimpleAlert(title: title, message: message)
        state = .disconnected
        shared.onConnectHandler?(nil, nil, error)
    }
    
    func finishConnection(_ mediaConnection: MediaConnection) {
        if connectingAlertController != nil {
            connectingAlertController.dismiss(animated: true) {
                self.basicFinishConnection(mediaConnection)
            }
            connectingAlertController = nil
        } else {
            basicFinishConnection(mediaConnection)
        }
    }
    
    func basicFinishConnection(_ mediaConnection: MediaConnection) {
        state = .connected
        
        NotificationCenter.default.addObserver(
            forName: MediaConnection.NotificationKey.onDisconnect,
            object: mediaConnection,
            queue: nil)
        { ntf in
            if self.state != .disconnected {
                self.disconnect()
            }
        }
        
        mediaConnection.mainMediaStream!.startConnectionTimer(timeInterval: 1) {
            seconds in
            if let seconds = seconds {
                DispatchQueue.main.async {
                    let text = String(format: "%02d:%02d:%02d",
                                      arguments: [seconds/(60*60), seconds/60, seconds%60])
                    self.connectionTimeValueLabel.text = text
                }
            }
        }
        shared.onConnectHandler?(connection, roles, nil)
        back(self)
    }
    
    func presentSimpleAlert(title: String? = nil, message: String? = nil) {
        let alert = UIAlertController(title: title,
                                      message: message,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) {
            action in return
        })
        present(alert, animated: true) {}
    }
    
    @IBAction func switchMicrophoneEnabled(_ sender: AnyObject) {
        guard let pub = connection?.mediaPublisher else { return }
        guard pub.isAvailable else { return }
        
        pub.microphoneEnabled = enableMicrophoneSwitch.isOn
    }
    
    @IBAction func switchSnapshotEnabled(_ sender: AnyObject) {
        snapshotEnabled = enableSnapshotSwitch.isOn
    }
    
    // MARK: テキストフィールドの編集
    
    @IBAction func hostTextFieldDidTouchDown(_ sender: AnyObject) {
        touchedField = hostTextField
    }
    
    @IBAction func hostTextFieldEditingDidEndOnExit(_ sender: AnyObject) {
        touchedField = nil
    }
    
    @IBAction func portTextFieldDidTouchDown(_ sender: AnyObject) {
        touchedField = portTextField
    }
    
    @IBAction func portTextFieldEditingDidEndOnExit(_ sender: AnyObject) {
        touchedField = nil
    }
    
    @IBAction func signalingPathTextFieldDidTouchDown(_ sender: AnyObject) {
        touchedField = signalingPathTextField
    }
    
    @IBAction func signalingPathTextFieldEditingDidEndOnExit(_ sender: AnyObject) {
        touchedField = nil
    }
    
    @IBAction func channelIdTextFieldDidTouchDown(_ sender: AnyObject) {
        touchedField = channelIdTextField
    }
    
    @IBAction func channelIdTextFieldEditingDidEndOnExit(_ sender: AnyObject) {
        touchedField = nil
    }
    
    @IBAction func handleTap(sender: UITapGestureRecognizer) {
        if sender.state == .ended {
            hostTextField.resignFirstResponder()
            portTextField.resignFirstResponder()
            signalingPathTextField.resignFirstResponder()
            channelIdTextField.resignFirstResponder()
        }
    }
    
}
