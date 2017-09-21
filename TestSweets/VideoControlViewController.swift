import UIKit

class VideoControlViewController: UITableViewController, TestCaseControllable {

    @IBOutlet weak var cameraAutofocusSwitch: UISwitch!
    @IBOutlet weak var muteMicrophoneSwitch: UISwitch!
    
    @IBOutlet weak var disconnectCell: UITableViewCell!

    weak var testCaseController: TestCaseController!
    
    override func viewDidLoad() {
        super.viewDidLoad()

        // Uncomment the following line to preserve selection between presentations
        // self.clearsSelectionOnViewWillAppear = false

        // Uncomment the following line to display an Edit button in the navigation bar for this view controller.
        // self.navigationItem.rightBarButtonItem = self.editButtonItem
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if let cell = tableView.cellForRow(at: indexPath) {
            tableView.deselectRow(at: indexPath, animated: true)
            if cell == disconnectCell {
                testCaseController.disconnect(error: nil)
            }
        }
    }
    
    // MARK: - Navigation

    // In a storyboard-based application, you will often want to do a little preparation before navigation
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if var vc = segue.destination as? TestCaseControllable {
            vc.testCaseController = testCaseController
        }
    }

    @IBAction func switchCameraAutofocus(_ sender: Any) {
        
    }
    
    @IBAction func switchMuteMicrophone(_ sender: Any) {
        
    }

}
