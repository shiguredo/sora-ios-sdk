import UIKit

class RoleViewController: UITableViewController {

    struct Component {
        var label: UILabel
        var cell: UITableViewCell
    }
    
    @IBOutlet weak var publisherLabel: UILabel!
    @IBOutlet weak var publisherCell: UITableViewCell!
    @IBOutlet weak var subscriberLabel: UILabel!
    @IBOutlet weak var subscriberCell: UITableViewCell!

    var main: ConnectionViewController {
        get { return ConnectionViewController.main! }
    }
    
    lazy var components: [ConnectionController.Role: Component] = [
        .publisher: Component(label: self.publisherLabel, cell: self.publisherCell),
        .subscriber: Component(label: self.subscriberLabel, cell: self.subscriberCell)
    ]
    
    override func viewDidLoad() {
        super.viewDidLoad()

        // Do any additional setup after loading the view.
        for label: UILabel in [publisherLabel, subscriberLabel] {
            label.font = UIFont.preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        clearCheckmarks()
        for role in ConnectionController.Role.allRoles {
            let comp = components[role]!
            if main.connectionController!.availableRoles.contains(role) {
                comp.label.textColor = UIColor.black
                comp.cell.isUserInteractionEnabled = true
                if main.roles.contains(role) {
                    comp.cell.accessoryType = .checkmark
                }
            } else {
                comp.label.textColor = UIColor.lightGray
                comp.cell.accessoryType = .none
                comp.cell.isUserInteractionEnabled = false
            }
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
        publisherCell?.accessoryType = .none
        subscriberCell?.accessoryType = .none
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch indexPath.row {
        case 0:
            selectRole(.publisher)
        case 1:
            selectRole(.subscriber)
        default:
            break
        }
    }
    
    func selectRole(_ role: ConnectionController.Role) {
        guard main.connectionController!.availableRoles.contains(role) else {
            return
        }
        
        if main.roles.count > 1 && main.roles.contains(role) {
            main.removeRole(role)
            components[role]?.cell.accessoryType = .none
        } else {
            main.addRole(role)
            components[role]?.cell.accessoryType = .checkmark
        }
    }
    
}
