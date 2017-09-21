import UIKit
import Sora

class MainViewController: UITableViewController {
    
    var testCaseControllers: [TestCaseController] = []
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        TestSuiteManager.shared.onAddHandler = { testCase in
            let cont = TestCaseController(testCase: testCase)
            self.testCaseControllers.append(cont)
            self.tableView.reloadData()
        }
        
        loadTestCases()
        navigationItem.leftBarButtonItem = editButtonItem
    }

    func loadTestCases() {
        TestSuiteManager.shared.load()
        testCaseControllers = []
        for testCase in TestSuiteManager.shared.testCases {
            testCaseControllers.append(TestCaseController(testCase: testCase))
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

    // MARK: - Table view data source

    override func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return testCaseControllers.count
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "testCaseName",
                                                 for: indexPath)
        cell.accessoryType = .disclosureIndicator
        let title = testCaseControllers[indexPath.row].testCase.title
        if title.isEmpty {
            cell.textLabel?.textColor = UIColor.lightGray
            cell.textLabel?.text = "No Name"
        } else {
            cell.textLabel?.textColor = UIColor.black
            cell.textLabel?.text = title
        }
        return cell
    }

    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let testCaseController = testCaseControllers[indexPath.row]
        if testCaseController.viewController == nil {
            testCaseController.viewController =
                createTestCaseViewController(testCaseController: testCaseController)
        }
        let vc = testCaseController.viewController!
        vc.navigationItem.title = "Test Case"
        vc.reloadTestCase()
        navigationController?.pushViewController(vc, animated: true)
    }
    
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

    // Override to support rearranging the table view.
    override func tableView(_ tableView: UITableView, moveRowAt fromIndexPath: IndexPath, to: IndexPath) {
        let testCase = testCaseControllers[fromIndexPath.row].testCase!
        TestSuiteManager.shared.remove(testCase: testCase)
        TestSuiteManager.shared.insert(testCase: testCase, at: to.row)
    }

    // Override to support conditional rearranging of the table view.
    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        // Return false if you do not want the item to be re-orderable.
        return true
    }

    // MARK: Table View の編集
    
    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        tableView.isEditing = editing
        
    }
    
    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }
    
    override func tableView(_ tableView: UITableView,
                            commit editingStyle: UITableViewCellEditingStyle,
                            forRowAt indexPath: IndexPath) {
        switch editingStyle {
        case .delete:
            TestSuiteManager.shared.save { manager in
                manager.remove(testCaseAt: indexPath.row)
            }
            testCaseControllers.remove(at: indexPath.row)
            tableView.deleteRows(at: [indexPath], with: .fade)
        default:
            break
        }
    }
    
    // MARK: アクション
    
    func createTestCaseViewController(testCaseController: TestCaseController) -> TestCaseViewController {
        let vc = storyboard!
            .instantiateViewController(withIdentifier: "TestCaseViewController")
            as! TestCaseViewController
        vc.testCaseController = testCaseController
        return vc
    }
    
    @IBAction func addNewConfiguration(_ sender: Any) {
        let id = Utilities.randomString()
        let config = Configuration(url: URL(string: "wss:///signaling")!,
                                   channelId: Utilities.randomString(),
                                   role: .publisher)
        let title = "Configuration \(testCaseControllers.count+1)"
        let testCase = TestCase(id: id, title: title, configuration: config)
        TestSuiteManager.shared.save { manager in
            manager.add(testCase: testCase)
        }
        tableView.reloadData()
    }
    
}
