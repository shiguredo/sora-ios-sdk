import UIKit

class RoleViewController: UITableViewController {

    struct Component {
        var role: ConnectionController.Role
        var label: UILabel
        var cell: UITableViewCell
    }
    
    @IBOutlet weak var publisherLabel: UILabel!
    @IBOutlet weak var publisherCell: UITableViewCell!
    @IBOutlet weak var subscriberLabel: UILabel!
    @IBOutlet weak var subscriberCell: UITableViewCell!

    var connectionController: ConnectionController {
        get { return ConnectionController.shared }
    }
    
    lazy var components: [Component] = [
        Component(role: .publisher, label: self.publisherLabel, cell: self.publisherCell),
        Component(role: .subscriber, label: self.subscriberLabel, cell: self.subscriberCell)
    ]
    
    var selectedRoles: [ConnectionController.Role] = [] {
        didSet {
            for comp in components {
                comp.cell.accessoryType = .none
                comp.label.textColor = UIColor.lightGray
                comp.cell.isUserInteractionEnabled = false
            }
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        selectedRoles = connectionController.roles
    }
    
    override func willMove(toParentViewController parent: UIViewController?) {
        if parent == nil {
            connectionController.roles = selectedRoles
        }
    }
    
    func selectRole(_ role: ConnectionController.Role) {
        var roles = selectedRoles
        if roles.contains(role) {
            selectedRoles = roles.filter { each in role != each }
        } else {
            roles.append(role)
            selectedRoles = roles
        }
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        selectRole(components[indexPath.row].role)
    }
    
}
