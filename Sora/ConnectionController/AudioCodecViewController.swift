import UIKit

class AudioCodecViewController: UITableViewController {
    
    @IBOutlet weak var defaultLabel: UILabel!
    @IBOutlet weak var OpusLabel: UILabel!
    @IBOutlet weak var PCMULabel: UILabel!
    
    @IBOutlet weak var defaultCell: UITableViewCell!
    @IBOutlet weak var OpusCell: UITableViewCell!
    @IBOutlet weak var PCMUCell: UITableViewCell!
    
    lazy var codecCells: [(AudioCodec, UITableViewCell)]! =
        [(.default, self.defaultCell), (.Opus, self.OpusCell), (.PCMU, self.PCMUCell)]


    var connectionController: ConnectionController {
        get { return ConnectionController.shared }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        selectedCodec = connectionController.audioCodec
    }
    
    override func willMove(toParentViewController parent: UIViewController?) {
        if parent == nil {
            connectionController.audioCodec = selectedCodec
        }
    }
    
    /*
    // MARK: - Navigation

    // In a storyboard-based application, you will often want to do a little preparation before navigation
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        // Get the new view controller using segue.destinationViewController.
        // Pass the selected object to the new view controller.
    }
    */
    
    var selectedCodec: AudioCodec? {
        didSet {
            for (codec, cell) in codecCells {
                if codec == selectedCodec {
                    cell.accessoryType = .checkmark
                } else {
                    cell.accessoryType = .none
                }
            }
            if selectedCodec == nil {
                defaultCell.accessoryType = .checkmark
            }
        }
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        selectedCodec = codecCells[indexPath.row].0
    }
    
}
