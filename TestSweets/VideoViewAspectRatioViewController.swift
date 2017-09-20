import UIKit

class VideoViewAspectRatioViewController: UITableViewController, TestCaseControllable {

    @IBOutlet weak var standardCell: UITableViewCell!
    @IBOutlet weak var wideCell: UITableViewCell!
    @IBOutlet weak var screenWidthCell: UITableViewCell!
    @IBOutlet weak var halfScreenWidthCell: UITableViewCell!
    
    weak var testCaseController: TestCaseController!

    var cells: [UITableViewCell] {
        get {
            return [standardCell,
                    wideCell,
                    screenWidthCell,
                    halfScreenWidthCell]
        }
    }
    
    var testCase: TestCase! {
        get { return testCaseController.testCase }
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
        switch testCase.videoViewAspectRatio {
        case .standard:
            standardCell.accessoryType = .checkmark
        case .wide:
            wideCell.accessoryType = .checkmark
        case .screenWidth:
            screenWidthCell.accessoryType = .checkmark
        case .halfScreenWidth:
            halfScreenWidthCell.accessoryType = .checkmark
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
        if cell == wideCell {
            wideCell.accessoryType = .checkmark
            testCase.videoViewAspectRatio = .wide
        } else if cell == screenWidthCell {
            screenWidthCell.accessoryType = .checkmark
            testCase.videoViewAspectRatio = .screenWidth
        } else if cell == halfScreenWidthCell {
            halfScreenWidthCell.accessoryType = .checkmark
            testCase.videoViewAspectRatio = .halfScreenWidth
        } else {
            standardCell.accessoryType = .checkmark
            testCase.videoViewAspectRatio = .standard
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
