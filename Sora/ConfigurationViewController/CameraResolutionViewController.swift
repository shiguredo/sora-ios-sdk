import UIKit

class CameraResolutionViewController: UITableViewController, ConfigurationViewControllable {

    @IBOutlet weak var qvgaCell: UITableViewCell!
    @IBOutlet weak var vgaCell: UITableViewCell!
    @IBOutlet weak var hdCell: UITableViewCell!
    @IBOutlet weak var fullHDCell: UITableViewCell!

    weak var configurationViewController: ConfigurationViewController?

    var selectedResolution: CameraVideoCapturer.Settings.Resolution = .qvga240p {
        didSet {
            qvgaCell.accessoryType = .none
            vgaCell.accessoryType = .none
            hdCell.accessoryType = .none
            fullHDCell.accessoryType = .none
            switch selectedResolution {
            case .qvga240p:
                qvgaCell.accessoryType = .checkmark
            case .vga480p:
                vgaCell.accessoryType = .checkmark
            case .hd720p:
                hdCell.accessoryType = .checkmark
            case .hd1080p:
                fullHDCell.accessoryType = .checkmark
            }
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        selectedResolution = configurationViewController?.cameraResolution ??
            CameraVideoCapturer.Settings.default.resolution
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

    
    override func willMove(toParentViewController parent: UIViewController?) {
        if parent == nil {
            configurationViewController?.cameraResolution = selectedResolution
        }
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        print("index path = \(indexPath.row)")
        switch indexPath.row {
        case 0:
            selectedResolution = .qvga240p
        case 1:
            selectedResolution = .vga480p
        case 2:
            selectedResolution = .hd720p
        case 3:
            selectedResolution = .hd1080p
        default:
            selectedResolution = CameraVideoCapturer.Settings.default.resolution
        }
    }
    
}
