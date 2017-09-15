import UIKit

class RoleViewController: UITableViewController, ConfigurationViewControllable {

    @IBOutlet weak var publisherCell: UITableViewCell!
    @IBOutlet weak var subscriberCell: UITableViewCell!
    @IBOutlet weak var groupCell: UITableViewCell!

    weak var configurationViewController: ConfigurationViewController?
    
    var selectedRole: Role? {
        didSet {
            publisherCell.accessoryType = .none
            subscriberCell.accessoryType = .none
            groupCell.accessoryType = .none
            if let role = selectedRole {
                switch role {
                case .publisher:
                    publisherCell.accessoryType = .checkmark
                case .subscriber:
                    subscriberCell.accessoryType = .checkmark
                case .group:
                    groupCell.accessoryType = .checkmark
                }
            } else {
                publisherCell.accessoryType = .checkmark
            }
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        selectedRole = configurationViewController?.role
    }
    
    override func willMove(toParentViewController parent: UIViewController?) {
        if parent == nil {
            if let role = selectedRole {
                configurationViewController?.role = role
            }
        }
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch indexPath.row {
        case 0:
            selectedRole = .publisher
        case 1:
            selectedRole = .subscriber
        case 2:
            selectedRole = .group
        default:
            selectedRole = .publisher
        }
    }
    
}
