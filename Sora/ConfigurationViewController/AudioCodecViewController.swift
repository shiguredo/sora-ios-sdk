import UIKit

class AudioCodecViewController: UITableViewController, ConfigurationViewControllable {
    
    @IBOutlet weak var defaultCell: UITableViewCell!
    @IBOutlet weak var opusCell: UITableViewCell!
    @IBOutlet weak var pcmuCell: UITableViewCell!
    
    weak var configurationViewController: ConfigurationViewController?

    var selectedCodec: AudioCodec = .default {
        didSet {
            defaultCell.accessoryType = .none
            opusCell.accessoryType = .none
            pcmuCell.accessoryType = .none
            switch selectedCodec {
            case .default:
                defaultCell.accessoryType = .checkmark
            case .opus:
                opusCell.accessoryType = .checkmark
            case .pcmu:
                pcmuCell.accessoryType = .checkmark
            }
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        selectedCodec = configurationViewController?.audioCodec ?? .default
    }
    
    override func willMove(toParentViewController parent: UIViewController?) {
        if parent == nil {
            configurationViewController?.audioCodec = selectedCodec
        }
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch indexPath.row {
        case 1:
            selectedCodec = .opus
        case 2:
            selectedCodec = .pcmu
        default:
            selectedCodec = .default
        }
    }
    
}
