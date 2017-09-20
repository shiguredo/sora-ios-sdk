import UIKit

class VideoCodecViewController: UITableViewController, ConfigurationViewControllable {

    @IBOutlet weak var defaultCell: UITableViewCell!
    @IBOutlet weak var vp8Cell: UITableViewCell!
    @IBOutlet weak var vp9Cell: UITableViewCell!
    @IBOutlet weak var h264Cell: UITableViewCell!
    
    weak var configurationViewController: ConfigurationViewController?
    
    var selectedCodec: VideoCodec = .default {
        didSet {
            configurationViewController?.videoCodec = selectedCodec
            defaultCell.accessoryType = .none
            vp8Cell.accessoryType = .none
            vp9Cell.accessoryType = .none
            h264Cell.accessoryType = .none
            switch selectedCodec {
            case .default:
                defaultCell.accessoryType = .checkmark
            case .vp8:
                vp8Cell.accessoryType = .checkmark
            case .vp9:
                vp9Cell.accessoryType = .checkmark
            case .h264:
                h264Cell.accessoryType = .checkmark
            }
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        selectedCodec = configurationViewController?.videoCodec ?? .default
    }
    
    override func willMove(toParentViewController parent: UIViewController?) {
        if parent == nil {
            configurationViewController?.videoCodec = selectedCodec
        }
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch indexPath.row {
        case 1:
            selectedCodec = .vp8
        case 2:
            selectedCodec = .vp9
        case 3:
            selectedCodec = .h264
        default:
            selectedCodec = .default
        }
    }
    
}
