import UIKit

class BitRateViewController: UITableViewController, ConfigurationViewControllable {
    
    @IBOutlet weak var valueDefaultCell: UITableViewCell!
    @IBOutlet weak var value100Cell: UITableViewCell!
    @IBOutlet weak var value300Cell: UITableViewCell!
    @IBOutlet weak var value500Cell: UITableViewCell!
    @IBOutlet weak var value800Cell: UITableViewCell!
    @IBOutlet weak var value1000Cell: UITableViewCell!
    @IBOutlet weak var value1500Cell: UITableViewCell!
    @IBOutlet weak var value2000Cell: UITableViewCell!
    @IBOutlet weak var value2500Cell: UITableViewCell!
    @IBOutlet weak var value3000Cell: UITableViewCell!
    @IBOutlet weak var value5000Cell: UITableViewCell!
    
    static var selectionValues: [Int?] =
        [nil, 100, 300, 500, 800, 1000, 1500, 2000, 2500, 3000, 5000]
    
    weak var configurationViewController: ConfigurationViewController?
    
    var allValueCells: [UITableViewCell] {
        get {
            return [valueDefaultCell,
                    value100Cell,
                    value300Cell,
                    value500Cell,
                    value800Cell,
                    value1000Cell,
                    value1500Cell,
                    value2000Cell,
                    value2500Cell,
                    value3000Cell,
                    value5000Cell]
        }
    }
    
    var selectedBitRate: Int? {
        didSet {
            for cell: UITableViewCell in allValueCells {
                cell.accessoryType = .none
            }
            if let bitRate = selectedBitRate {
                cellForBitRate(bitRate).accessoryType = .checkmark
            } else {
                valueDefaultCell.accessoryType = .checkmark
            }
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        selectedBitRate = configurationViewController?.videoBitRate
    }
    
    func cellForBitRate(_ value: Int) -> UITableViewCell {
        switch value {
        case 0...100:
            return value100Cell
        case 100...300:
            return value300Cell
        case 300...500:
            return value500Cell
        case 500...800:
            return value800Cell
        case 800...1000:
            return value1000Cell
        case 1000...1500:
            return value1500Cell
        case 1500...2000:
            return value2000Cell
        case 2000...2500:
            return value2500Cell
        case 2500...3000:
            return value3000Cell
        default:
            return value5000Cell
        }
    }
    
    override func willMove(toParentViewController parent: UIViewController?) {
        if parent == nil {
            configurationViewController?.videoBitRate = selectedBitRate
        }
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        selectedBitRate = BitRateViewController.selectionValues[indexPath.row]
    }
    
}
