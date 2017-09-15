import UIKit

public class ConnectionController: UIViewController {

    public enum Role {
        case publisher
        case subscriber
        
        static var allRoles: [Role] = [.publisher, .subscriber]
        
        static func containsAll(_ roles: [Role]) -> Bool {
            let allRoles: [Role] = [.publisher, .subscriber]
            for role in roles {
                if !allRoles.contains(role) {
                    return false
                }
            }
            return true
        }
    }
    
    public enum StreamType {
        case single
        case multiple
    }

    public class Request {
        
        public var URL: URL
        public var channelId: String
        public var roles: [Role]
        public var multistreamEnabled: Bool
        public var snapshotEnabled: Bool
        public var videoEnabled: Bool
        public var videoCodec: VideoCodec
        public var bitRate: Int
        public var audioEnabled: Bool
        public var audioCodec: AudioCodec
        
        public init(URL: URL,
                    channelId: String,
                    roles: [Role],
                    multistreamEnabled: Bool,
                    videoEnabled: Bool,
                    videoCodec: VideoCodec,
                    bitRate: Int,
                    snapshotEnabled: Bool,
                    audioEnabled: Bool,
                    audioCodec: AudioCodec) {
            self.URL = URL
            self.channelId = channelId
            self.roles = roles
            self.multistreamEnabled = multistreamEnabled
            self.videoEnabled = videoEnabled
            self.videoCodec = videoCodec
            self.bitRate = bitRate
            self.snapshotEnabled = snapshotEnabled
            self.audioEnabled = audioEnabled
            self.audioCodec = audioCodec
        }
        
    }
    
    enum UserDefaultsKey: String {
        case WebSocketSSLEnabled = "SoraConnectionControllerWebSocketSSLEnabled"
        case host = "SoraConnectionControllerHost"
        case port = "SoraConnectionControllerPort"
        case signalingPath = "SoraConnectionControllerSignalingPath"
        case channelId = "SoraConnectionControllerChannelId"
        case roles = "SoraConnectionControllerRoles"
        case multistreamEnabled = "SoraConnectionControllerMultistreamEnabled"
        case snapshotEnabled = "SoraConnectionControllerSnapshotEnabled"
        case videoEnabled = "SoraConnectionControllerVideoEnabled"
        case videoCodec = "SoraConnectionControllerVideoCodec"
        case bitRate = "SoraConnectionControllerBitRate"
        case audioEnabled = "SoraConnectionControllerAudioEnabled"
        case audioCodec = "SoraConnectionControllerAudioCodec"
        case autofocusEnabled = "SoraConnectionControllerAutofocusEnabled"
    }
    
    static var shared: ConnectionController!
    
    static var defaultBitRate: Int = 800
    
    static var userDefaultsDidLoadNotificationName: Notification.Name
        = Notification.Name("SoraConnectionControllerUserDefaultsDidLoad")
    
    public var connection: Connection?
    
    var connectionControllerStoryboard: UIStoryboard?
    var connectionNavigationController: ConnectionNavigationController!
    
    public var WebSocketSSLEnabled: Bool = true
    public var host: String?
    public var port: Int?
    public var signalingPath: String?
    public var channelId: String?
    public var roles: [Role] = [.publisher, .subscriber]
    public var autofocusEnabled: Bool = false
    public var multistreamEnabled: Bool = false
    public var snapshotEnabled: Bool = false
    public var videoEnabled: Bool = true
    public var videoCodec: VideoCodec? = .default
    public var bitRate: Int? = 800
    public var audioEnabled: Bool = true
    public var audioCodec: AudioCodec? = .default
    
    public var availableRoles: [Role] = [.publisher, .subscriber]
    public var availableStreamTypes: [StreamType] = [.single, .multiple]
    public var userDefaultsSuiteName: String? = "jp.shiguredo.SoraConnectionController"
    
    public var userDefaults: UserDefaults? {
        get { return UserDefaults(suiteName: userDefaultsSuiteName) }
    }
    
    var tupleOfAvailableStreamTypes: (Bool, Bool) {
        get {
            return (availableStreamTypes.contains(.single),
                    availableStreamTypes.contains(.multiple))
        }
    }
    
    // MARK: Initialization
    
    public init(WebSocketSSLEnabled: Bool = true,
                host: String? = nil,
                port: Int? = nil,
                signalingPath: String? = "signaling",
                channelId: String? = nil,
                availableRoles: [Role]? = nil,
                availableStreamTypes: [StreamType]? = nil,
                userDefaultsSuiteName: String? = nil,
                useUserDefaults: Bool = true) {
        super.init(nibName: nil, bundle: nil)
        connectionControllerStoryboard =
            UIStoryboard(name: "ConnectionController",
                         bundle: Bundle(for: ConnectionController.self))
        guard let navi = connectionControllerStoryboard?
            .instantiateViewController(withIdentifier: "Navigation")
            as! ConnectionNavigationController? else {
            fatalError("failed loading ConnectionViewController")
        }
        connectionNavigationController = navi        
        addChildViewController(connectionNavigationController)
        view.addSubview(connectionNavigationController.view)
        connectionNavigationController.didMove(toParentViewController: self)
        
        self.WebSocketSSLEnabled = WebSocketSSLEnabled
        self.host = host
        self.port = port
        self.signalingPath = signalingPath
        self.channelId = channelId
        if let roles = availableRoles {
            self.availableRoles = roles
        }
        if let streamTypes = availableStreamTypes {
            self.availableStreamTypes = streamTypes
        }
        self.userDefaultsSuiteName = userDefaultsSuiteName
        
        if useUserDefaults {
            loadFromUserDefaults()
        }
        
        ConnectionController.shared = self
    }
    
    required public init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override public func viewDidLoad() {
        super.viewDidLoad()
    }

    override public func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    /*
    // MARK: Navigation

    // In a storyboard-based application, you will often want to do a little preparation before navigation
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        // Get the new view controller using segue.destinationViewController.
        // Pass the selected object to the new view controller.
    }
    */

    var onRequestHandler: ((Connection, Request) -> Void)?
    var onConnectHandler: ((Connection?, [Role]?, ConnectionError?) -> Void)?

    public func onRequest(handler: @escaping (Connection, Request) -> Void) {
        onRequestHandler = handler
    }
    
    public func onConnect(handler:
        @escaping (Connection?, [Role]?, ConnectionError?) -> Void) {
        onConnectHandler = handler
    }
    
    // MARK: User Defaults
    
    func loadFromUserDefaults() {
        guard let defaults = userDefaults else {
            return
        }
        
        WebSocketSSLEnabled = defaults.bool(forKey: UserDefaultsKey.WebSocketSSLEnabled.rawValue)
        if let host = defaults.string(forKey: UserDefaultsKey.host.rawValue) {
            self.host = host
        }
        port = defaults.integer(forKey: UserDefaultsKey.port.rawValue)
        if port == 0 {
            port = nil
        }
        if let signalingPath = defaults.string(forKey: UserDefaultsKey.signalingPath.rawValue) {
            self.signalingPath = signalingPath
        }
        if let channelId = defaults.string(forKey: UserDefaultsKey.channelId.rawValue) {
            self.channelId = channelId
        }

        var roles: [Role] = []
        if let value = defaults.string(forKey:
            ConnectionController.UserDefaultsKey.roles.rawValue) {
            if value.contains("p") {
                roles.append(.publisher)
            }
            if value.contains("s") {
                roles.append(.subscriber)
            }
        }
        if !roles.isEmpty {
            self.roles = roles
        }
        
        multistreamEnabled = defaults.bool(forKey: UserDefaultsKey.multistreamEnabled.rawValue)
        snapshotEnabled = defaults.bool(forKey: UserDefaultsKey.snapshotEnabled.rawValue)
        videoEnabled = defaults.bool(forKey: UserDefaultsKey.videoEnabled.rawValue)
        bitRate = defaults.integer(forKey: UserDefaultsKey.bitRate.rawValue)
        if bitRate == 0 {
            bitRate = ConnectionController.defaultBitRate
        }
        audioEnabled = defaults.bool(forKey: UserDefaultsKey.audioEnabled.rawValue)
        autofocusEnabled = defaults.bool(forKey: UserDefaultsKey.autofocusEnabled.rawValue)
        
        videoCodec = nil
        if let name = defaults.string(forKey: UserDefaultsKey.videoCodec.rawValue) {
            videoCodec = ConnectionViewController.videoCodecTable.value(text: name)
        }

        audioCodec = nil
        if let name = defaults.string(forKey: UserDefaultsKey.audioCodec.rawValue) {
            audioCodec = ConnectionViewController.audioCodecTable.value(text: name)
        }
        
        NotificationCenter.default.post(name: ConnectionController
            .userDefaultsDidLoadNotificationName, object: self)
    }
    
    func saveToUserDefaults() {
        guard let defaults = userDefaults else {
            return
        }
        
        defaults.set(WebSocketSSLEnabled,
                     forKey: UserDefaultsKey.WebSocketSSLEnabled.rawValue)
        defaults.set(host, forKey: UserDefaultsKey.host.rawValue)
        defaults.set(port, forKey: UserDefaultsKey.port.rawValue)
        defaults.set(signalingPath, forKey: UserDefaultsKey.signalingPath.rawValue)
        defaults.set(channelId, forKey: UserDefaultsKey.channelId.rawValue)
        
        var roleValue = ""
        if roles.contains(.publisher) {
            roleValue.append("p")
        }
        if roles.contains(.subscriber) {
            roleValue.append("s")
        }
        if roleValue.isEmpty {
            roleValue = "ps"
        }
        
        defaults.set(roleValue, forKey: UserDefaultsKey.roles.rawValue)
        defaults.set(multistreamEnabled,
                     forKey: UserDefaultsKey.multistreamEnabled.rawValue)
        defaults.set(snapshotEnabled,
                     forKey: UserDefaultsKey.snapshotEnabled.rawValue)
        defaults.set(videoEnabled, forKey: UserDefaultsKey.videoEnabled.rawValue)
        defaults.set(bitRate, forKey: UserDefaultsKey.bitRate.rawValue)
        defaults.set(audioEnabled, forKey: UserDefaultsKey.audioEnabled.rawValue)
        defaults.set(autofocusEnabled,
                     forKey: UserDefaultsKey.autofocusEnabled.rawValue)
        
        var videoCodecValue: String?
        switch videoCodec {
        case .VP8?:
            videoCodecValue = "VP8"
        case .VP9?:
            videoCodecValue = "VP9"
        case .H264?:
            videoCodecValue = "H.264"
        default:
            videoCodecValue = nil
        }
        defaults.set(videoCodecValue, forKey: UserDefaultsKey.videoCodec.rawValue)
        
        var audioCodecValue: String?
        switch audioCodec {
        case .Opus?:
            audioCodecValue = "Opus"
        case .PCMU?:
            audioCodecValue = "PCMU"
        default:
            audioCodecValue = nil
        }
        defaults.set(audioCodecValue, forKey: UserDefaultsKey.audioCodec.rawValue)
        
        defaults.synchronize()
    }
    
}

extension ConnectionController {
    
    struct Action {
        
        static let updateWebSocketSSLEnabled =
            #selector(ConnectionController.updateWebSocketSSLEnabled(_:))
        static let updateHost =
            #selector(ConnectionController.updateHost(_:))
        static let updatePort =
            #selector(ConnectionController.updatePort(_:))
        static let updateSignalingPath =
            #selector(ConnectionController.updateSignalingPath(_:))
        static let updateChannelId =
            #selector(ConnectionController.updateChannelId(_:))
        static let updateMultistreamEnabled =
            #selector(ConnectionController.updateMultistreamEnabled(_:))
        static let updateVideoEnabled =
            #selector(ConnectionController.updateVideoEnabled(_:))
        static let updateSnapshotEnabled =
            #selector(ConnectionController.updateSnapshotEnabled(_:))
        static let updateAudioEnabled =
            #selector(ConnectionController.updateAudioEnabled(_:))
        static let updateAutofocus =
            #selector(ConnectionController.updateAutofocus(_:))
        
    }
    
    func updateWebSocketSSLEnabled(_ sender: AnyObject) {
        if let control = sender as? UISwitch {
            WebSocketSSLEnabled = control.isOn
        }
    }
    
    func updateHost(_ sender: AnyObject) {
        if let control = sender as? UITextField {
            host = control.text
        }
    }
    
    func updatePort(_ sender: AnyObject) {
        if let control = sender as? UITextField {
            if let text = control.text {
                port = Int(text)
            }
        }
    }
    
    func updateSignalingPath(_ sender: AnyObject) {
        if let control = sender as? UITextField {
            signalingPath = control.text
        }
    }
    
    func updateChannelId(_ sender: AnyObject) {
        if let control = sender as? UITextField {
            channelId = control.text
        }
    }
    
    func updateMultistreamEnabled(_ sender: AnyObject) {
        if let control = sender as? UISwitch {
            multistreamEnabled = control.isOn
        }
    }
    
    func updateVideoEnabled(_ sender: AnyObject) {
        if let control = sender as? UISwitch {
            videoEnabled = control.isOn
        }
    }
    
    func updateSnapshotEnabled(_ sender: AnyObject) {
        if let control = sender as? UISwitch {
            snapshotEnabled = control.isOn
        }
    }
    
    func updateAudioEnabled(_ sender: AnyObject) {
        if let control = sender as? UISwitch {
            audioEnabled = control.isOn
        }
    }
    
    func updateAutofocus(_ sender: AnyObject) {
        if let control = sender as? UISwitch {
            autofocusEnabled = control.isOn
        }
    }
    
}
