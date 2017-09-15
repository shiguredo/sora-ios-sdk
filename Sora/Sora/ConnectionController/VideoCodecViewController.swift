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
    
    override func viewDidLoad() {
        super.viewDidLoad()

        // Do any additional setup after loading the view.
        for label: UILabel in [defaultLabel, VP8Label, VP9Label, H264Label] {
            label.font = UIFont.preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        clearCheckmarks()
        switch ConnectionViewController.main?.videoCodec {
        case .default?, nil:
            defaultCell.accessoryType = .checkmark
        case .VP8?:
            VP8Cell.accessoryType = .checkmark
        case .VP9?:
            VP9Cell.accessoryType = .checkmark
        case .H264?:
            H264Cell.accessoryType = .checkmark
        }
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

    func clearCheckmarks() {
        defaultCell?.accessoryType = .none
        VP8Cell?.accessoryType = .none
        VP9Cell?.accessoryType = .none
        H264Cell?.accessoryType = .none
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        clearCheckmarks()
        switch indexPath.row {
        case 0:
            ConnectionViewController.main?.videoCodec = .default
            defaultCell?.accessoryType = .checkmark
        case 1:
            ConnectionViewController.main?.videoCodec = .VP8
            VP8Cell?.accessoryType = .checkmark
        case 2:
            ConnectionViewController.main?.videoCodec = .VP9
            VP9Cell?.accessoryType = .checkmark
        case 3:
            ConnectionViewController.main?.videoCodec = .H264
            H264Cell?.accessoryType = .checkmark
        default:
            break
        }
    }
    
}
