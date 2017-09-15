import UIKit

class AudioCodecViewController: UITableViewController {
    
    @IBOutlet weak var defaultLabel: UILabel!
    @IBOutlet weak var OpusLabel: UILabel!
    @IBOutlet weak var PCMULabel: UILabel!
    
    @IBOutlet weak var defaultCell: UITableViewCell!
    @IBOutlet weak var OpusCell: UITableViewCell!
    @IBOutlet weak var PCMUCell: UITableViewCell!
    
    override func viewDidLoad() {
        super.viewDidLoad()

        // Do any additional setup after loading the view.
        for label: UILabel in [defaultLabel, OpusLabel, PCMULabel] {
            label.font = UIFont.preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        selectCodec(codec: ConnectionViewController.main?.audioCodec)
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    

    /*
    // MARK: - Navigation

    // In a storyboard-based application, you will often want to do a little preparation before navigation
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        // Get the new view controller using segue.destinationViewController.
        // Pass the selected object to the new view controller.
    }
    */

    func selectCodec(codec: AudioCodec? = nil) {
        defaultCell.accessoryType = .none
        OpusCell.accessoryType = .none
        PCMUCell.accessoryType = .none
        switch codec {
        case .default?, nil:
            ConnectionViewController.main?.audioCodec = .default
            defaultCell?.accessoryType = .checkmark
        case .Opus?:
            ConnectionViewController.main?.audioCodec = .Opus
            OpusCell?.accessoryType = .checkmark
        case .PCMU?:
            ConnectionViewController.main?.audioCodec = .PCMU
            PCMUCell?.accessoryType = .checkmark
        }
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch indexPath.row {
        case 0:
            selectCodec(codec: .default)
        case 1:
            selectCodec(codec: .Opus)
        case 2:
            selectCodec(codec: .PCMU)
        default:
            break
        }
    }
    
}
