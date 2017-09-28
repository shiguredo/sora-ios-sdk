import UIKit

public protocol ConfigurationViewControllable: class {

    weak var configurationViewController: ConfigurationViewController? { get set }
    
}

let defaultSignalingPath = "signaling"

public class ConfigurationViewController: UIViewController {

    public var webSocketSSLEnabled: Bool = true
    public var host: String?
    public var port: Int?
    
    public var signalingPath: String? {
        didSet {
            if signalingPath == "" {
                signalingPath = nil
            }
        }
    }
    
    public var channelId: String? {
        didSet {
            if channelId == "" {
                channelId = nil
            }
        }
    }
    
    public var role: Role = .publisher
    public var snapshotEnabled: Bool = false
    public var videoEnabled: Bool = true
    public var videoCodec: VideoCodec = .default
    public var videoBitRate: Int? = 800
    public var audioEnabled: Bool = true
    public var audioCodec: AudioCodec = .default
    
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
            var config = Configuration(url: url ?? URL(string: "wss://")!,
                                       channelId: channelId ?? "",
                                       role: role)
            config.snapshotEnabled = snapshotEnabled
            config.videoEnabled = videoEnabled
            config.videoCodec = videoCodec
            config.videoBitRate = videoBitRate
            config.audioEnabled = audioEnabled
            config.audioCodec = audioCodec
            return config
        }
        
        set {
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
            snapshotEnabled = newValue.snapshotEnabled
            videoEnabled = newValue.videoEnabled
            videoCodec = newValue.videoCodec
            videoBitRate = newValue.videoBitRate
            audioEnabled = newValue.audioEnabled
            audioCodec = newValue.audioCodec
        }
        
    }
    
    var configurationViewControllerStoryboard: UIStoryboard?
    var configurationNavigationController: ConfigurationNavigationController!
    
    public func validate(handler: (Configuration?, String?) -> ()) {
        guard host != nil && channelId != nil else {
            handler(nil, "Host and channel ID must not be empty")
            return
        }

        guard url != nil else {
            handler(nil, "Invalid URL format")
            return
        }
        
        let config = configuration
        handler(config, nil)
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
    
}

