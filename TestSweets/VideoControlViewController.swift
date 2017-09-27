import UIKit

class VideoControlViewController: UITableViewController,
    UIGestureRecognizerDelegate,
    TestCaseControllable {

    @IBOutlet weak var cameraAutofocusSwitch: UISwitch!
    @IBOutlet weak var muteMicrophoneSwitch: UISwitch!
    
    @IBOutlet weak var disconnectCell: UITableViewCell!
    @IBOutlet weak var aspectRatioCell: UITableViewCell!
    @IBOutlet weak var numberOfColumnsTextField: UITextField!
    @IBOutlet weak var aspectRatioValueLabel: UILabel!

    weak var testCaseController: TestCaseController!
    
    var numberOfColumns: Int? {
        get {
            return testCaseController.testCase.numberOfItemsInVideoViewSection
        }
        set {
            testCaseController.testCase.numberOfItemsInVideoViewSection = newValue ?? 1
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()

        // Uncomment the following line to preserve selection between presentations
        // self.clearsSelectionOnViewWillAppear = false

        // Uncomment the following line to display an Edit button in the navigation bar for this view controller.
        // self.navigationItem.rightBarButtonItem = self.editButtonItem
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadData()
    }
    
    func reloadData() {
        guard let cont = testCaseController else {
            return
        }
        
        numberOfColumns = cont.testCase.numberOfItemsInVideoViewSection
        numberOfColumnsTextField.text = numberOfColumns?.description
        
        switch cont.testCase.videoViewAspectRatio {
        case .standard:
            aspectRatioValueLabel.text = "4:3"
        case .wide:
            aspectRatioValueLabel.text = "16:9"
        }
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
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        if let content = touch.view?.superview as? UITableViewCell {
            return content != disconnectCell && content != aspectRatioCell
        }
        return true
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

    @IBAction func numberOfColumnsTextFieldDidEndOnExit(_ sender: AnyObject) {
        print("numberOfColumnsTextFieldDidEndOnExit")
        if let text = numberOfColumnsTextField.text {
            numberOfColumns = Int(text)!
        } else {
            numberOfColumns = nil
        }
    }
    
    @IBAction func handleTap(_ sender: UITapGestureRecognizer) {
        if sender.state == .ended {
            numberOfColumnsTextFieldDidEndOnExit(sender)
            view.endEditing(true)
            reloadData()
        }
    }
    
}
