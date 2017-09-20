import UIKit

class VideoViewContentModeViewController: UITableViewController {

    @IBOutlet weak var scaleToFillCell: UITableViewCell!
    @IBOutlet weak var scaleAspectFitCell: UITableViewCell!
    @IBOutlet weak var scaleAspectFillCell: UITableViewCell!

    var videoControl: VideoControl!

    var cells: [UITableViewCell] {
        get {
            return [scaleToFillCell,
                    scaleAspectFitCell,
                    scaleAspectFillCell]
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()

        // Uncomment the following line to preserve selection between presentations
        // self.clearsSelectionOnViewWillAppear = false

        // Uncomment the following line to display an Edit button in the navigation bar for this view controller.
        // self.navigationItem.rightBarButtonItem = self.editButtonItem
    }

    func clearCheckmarks() {
        for cell in cells {
            cell.accessoryType = .none
        }
    }
    
    func reloadData() {
        clearCheckmarks()
        switch videoControl.contentMode {
        case .scaleToFill:
            scaleToFillCell.accessoryType = .checkmark
        case .scaleAspectFit:
            scaleAspectFitCell.accessoryType = .checkmark
        case .scaleAspectFill:
            scaleAspectFillCell.accessoryType = .checkmark
        default:
            scaleToFillCell.accessoryType = .checkmark
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadData()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

    // MARK: - Table view data source

    /*
    override func numberOfSections(in tableView: UITableView) -> Int {
        // #warning Incomplete implementation, return the number of sections
        return 0
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        // #warning Incomplete implementation, return the number of rows
        return 0
    }
 */
    
    /*
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "reuseIdentifier", for: indexPath)

        // Configure the cell...

        return cell
    }
    */

    /*
    // Override to support conditional editing of the table view.
    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        // Return false if you do not want the specified item to be editable.
        return true
    }
    */

    /*
    // Override to support editing the table view.
    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCellEditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            // Delete the row from the data source
            tableView.deleteRows(at: [indexPath], with: .fade)
        } else if editingStyle == .insert {
            // Create a new instance of the appropriate class, insert it into the array, and add a new row to the table view
        }    
    }
    */

    /*
    // Override to support rearranging the table view.
    override func tableView(_ tableView: UITableView, moveRowAt fromIndexPath: IndexPath, to: IndexPath) {

    }
    */

    /*
    // Override to support conditional rearranging of the table view.
    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        // Return false if you do not want the item to be re-orderable.
        return true
    }
    */
    
    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {
        clearCheckmarks()
        let cell = tableView.cellForRow(at: indexPath)
        if cell == scaleAspectFitCell {
            scaleAspectFitCell.accessoryType = .checkmark
            videoControl.contentMode = .scaleAspectFit
        } else if cell == scaleAspectFillCell {
            scaleAspectFillCell.accessoryType = .checkmark
            videoControl.contentMode = .scaleAspectFill
        } else {
            scaleToFillCell.accessoryType = .checkmark
            videoControl.contentMode = .scaleToFill
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

}
