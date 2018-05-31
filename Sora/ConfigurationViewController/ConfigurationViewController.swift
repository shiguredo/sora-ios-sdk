import UIKit

/// :nodoc:
public protocol ConfigurationViewControllable: class {

    var configurationViewController: ConfigurationViewController? { get set }
    
}

let defaultSignalingPath = "signaling"

/// :nodoc:
public final class ConfigurationViewController: UIViewController {

    public static var globalConfiguration: Configuration?
    
    public var globalConfigurationEnabled: Bool = false
    
    public var webSocketSSLEnabled: Bool = true {
        didSet {
            if isLocked {
                webSocketSSLEnabled = oldValue
            }
        }
    }
    
    public var host: String? {
        didSet {
            if isLocked {
                host = oldValue
            }
        }
    }
    
    public var port: Int? {
        didSet {
            if isLocked {
                port = oldValue
            }
        }
    }
    
    public var signalingPath: String? {
        didSet {
            if isLocked {
                signalingPath = oldValue
            } else {
                if signalingPath?.isEmpty ?? true {
                    signalingPath = nil
                }
            }
        }
    }
    
    public var channelId: String? {
        didSet {
            if isLocked {
                signalingPath = oldValue
            } else {
                if channelId?.isEmpty ?? true {
                    channelId = nil
                }
            }
        }
    }
    
    public var role: Role = .publisher {
        didSet {
            if isLocked {
                role = oldValue
            }
        }
    }
    
    public var maxNumberOfSpeakers: Int? {
        didSet {
            if isLocked {
                maxNumberOfSpeakers = oldValue
            }
        }
    }
    
    public var videoEnabled: Bool = true {
        didSet {
            if isLocked {
                videoEnabled = oldValue
            }
        }
    }
    
    public var videoCodec: VideoCodec = .default {
        didSet {
            if isLocked {
                videoCodec = oldValue
            }
        }
    }
    
    public var videoBitRate: Int? = 800 {
        didSet {
            if isLocked {
                videoBitRate = oldValue
            }
        }
    }
    
    public var cameraResolution: CameraVideoCapturer.Settings.Resolution =
        CameraVideoCapturer.Settings.default.resolution {
        didSet {
            if isLocked {
                cameraResolution = oldValue
            }
        }
    }
    
    public var cameraFrameRate: Int? {
        didSet {
            if isLocked {
                cameraFrameRate = oldValue
            }
        }
    }
    
    public var audioEnabled: Bool = true {
        didSet {
            if isLocked {
                audioEnabled = oldValue
            }
        }
    }
    
    public var audioCodec: AudioCodec = .default {
        didSet {
            if isLocked {
                audioCodec = oldValue
            }
        }
    }
    
    public var url: URL? {
        get {
            let urlStr = String(format: "%@://%@%@/%@",
                                webSocketSSLEnabled ? "wss" : "ws",
                                host ?? "",
                                port != nil ? ":" + String(port!) : "",
                                signalingPath != nil ? signalingPath! : defaultSignalingPath)
            let url = URL(string: urlStr)
            if url == nil {
                Logger.debug(type: .configurationViewController,
                          message: "Invalid URL string: \(urlStr)")
            }
            return url
        }
    }
        
    public var configuration: Configuration {
        
        get {
            var config: Configuration!
            if globalConfigurationEnabled {
                if let global = ConfigurationViewController.globalConfiguration {
                    config = Configuration(url: global.url,
                                           channelId: global.channelId,
                                           role: role)
                }
            }
            if config == nil {
                config = Configuration(url: url ?? URL(string: "wss://")!,
                                       channelId: channelId ?? "",
                                       role: role)
            }
            config.maxNumberOfSpeakers = maxNumberOfSpeakers
            config.videoEnabled = videoEnabled
            config.videoCodec = videoCodec
            config.videoBitRate = videoBitRate
            config.videoCapturerDevice =
                .camera(settings: CameraVideoCapturer
                    .Settings(resolution: cameraResolution,
                              frameRate: cameraFrameRate ??
                                CameraVideoCapturer.Settings.default.frameRate,
                              canStop: true))
            config.audioEnabled = audioEnabled
            config.audioCodec = audioCodec
            return config
        }
        
        set {
            guard !isLocked else { return }
            
            let url = newValue.url
            webSocketSSLEnabled = url.scheme == "wss"
            host = url.host
            port = url.port
            if url.path.isEmpty || url.path == "/" ||
                url.path == defaultSignalingPath ||
                url.path == "/" + defaultSignalingPath {
                signalingPath = nil
            } else {
                signalingPath = url.path
            }
            channelId = newValue.channelId
            role = newValue.role
            maxNumberOfSpeakers = newValue.maxNumberOfSpeakers
            videoEnabled = newValue.videoEnabled
            videoCodec = newValue.videoCodec
            videoBitRate = newValue.videoBitRate
            switch newValue.videoCapturerDevice {
            case .camera(settings: let settings):
                cameraResolution = settings.resolution
                cameraFrameRate = settings.frameRate
            default:
                break
            }
            audioEnabled = newValue.audioEnabled
            audioCodec = newValue.audioCodec
        }
        
    }
    
    public private(set) var isLocked: Bool = false

    var configurationViewControllerStoryboard: UIStoryboard?
    var configurationNavigationController: ConfigurationNavigationController!
    var onLockHandler: (() -> Void)?
    var onUnlockHandler: (() -> Void)?
    
    public func validate(handler: (Configuration?, String?) -> ()) {
        if !globalConfigurationEnabled {
            guard host != nil && channelId != nil else {
                handler(nil, "Host and channel ID must not be empty")
                return
            }
            guard url != nil else {
                handler(nil, "Invalid URL format")
                return
            }
        }
        
        handler(configuration, nil)
    }

    // MARK: Initialization
    
    public init() {
        super.init(nibName: nil, bundle: nil)
        configurationViewControllerStoryboard =
            UIStoryboard(name: "ConfigurationViewController",
                         bundle: Bundle(for: ConfigurationViewController.self))
        guard let navi = configurationViewControllerStoryboard?
            .instantiateViewController(withIdentifier: "Navigation")
            as! ConfigurationNavigationController? else {
            fatalError("failed loading ConfigurationMainViewController")
        }
        configurationNavigationController = navi
        configurationNavigationController.configurationViewController = self
        addChildViewController(configurationNavigationController)
        view.addSubview(configurationNavigationController.view)
        configurationNavigationController.didMove(toParentViewController: self)
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
    
    // MARK: Navigation

    func set(for segue: UIStoryboardSegue) {
        if let vc = segue.destination as? ConfigurationViewControllable {
            vc.configurationViewController = self
        }
    }
    
    // MARK: ロック
    
    // 設定変更不可にする
    public func lock() {
        guard !isLocked else { return }
        
        Logger.debug(type: .configurationViewController,
                     message: "lock configuration")
        isLocked = true
        onLockHandler?()
    }
    
    public func unlock() {
        guard isLocked else { return }
        
        Logger.debug(type: .configurationViewController,
                     message: "unlock configuration")
        isLocked = false
        onUnlockHandler?()
    }
}

