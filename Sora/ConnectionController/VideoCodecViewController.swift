import UIKit

class VideoCodecViewController: UITableViewController {

    @IBOutlet weak var defaultLabel: UILabel!
    @IBOutlet weak var VP8Label: UILabel!
    @IBOutlet weak var VP9Label: UILabel!
    @IBOutlet weak var H264Label: UILabel!
    
    @IBOutlet weak var defaultCell: UITableViewCell!
    @IBOutlet weak var VP8Cell: UITableViewCell!
    @IBOutlet weak var VP9Cell: UITableViewCell!
    @IBOutlet weak var H264Cell: UITableViewCell!
    
    lazy var codecCells: [(VideoCodec, UITableViewCell)] =
        [(.default, self.defaultCell), (.VP8, self.VP8Cell),
         (.VP9, self.VP9Cell), (.H264, self.H264Cell)]
    
    var connectionController: ConnectionController? {
        get {
            return (navigationController as! ConnectionNavigationController?)?
                .connectionController
        }
    }
    
    var selectedCodec: VideoCodec? {
        didSet {
            for (codec, cell) in codecCells {
                if codec == selectedCodec {
                    cell.accessoryType = .checkmark
                } else {
                    cell.accessoryType = .none
                }
            }
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
    }
    
    override func willMove(toParentViewController parent: UIViewController?) {
        if parent == nil {
            connectionController?.videoCodec = selectedCodec
        }
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        selectedCodec = codecCells[indexPath.row].0
    }
    
}
