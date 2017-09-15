import UIKit
import Sora

class MainViewController: UITableViewController {
    
    var testCases: [TestCase] {
        get { return TestSuiteManager.shared.testSuite.testCases }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        TestSuiteManager.shared.load()
        TestSuiteManager.shared.updateHandler.onExecute {
            self.tableView.reloadData()
        }

        navigationItem.leftBarButtonItem = editButtonItem
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
        return testCases.count
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "testCaseName",
                                                 for: indexPath)
        cell.accessoryType = .disclosureIndicator
        let title = testCases[indexPath.row].title
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
        let testCase = testCases[indexPath.row]
        if testCase.viewController == nil {
            testCase.viewController = createTestCaseViewController(testCase: testCase)
        }
        testCase.viewController!.navigationItem.title = "Test Case"
        testCase.viewController!.reloadTestCase()
        navigationController?.pushViewController(testCase.viewController!, animated: true)
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
        let testCase = testCases[fromIndexPath.row]
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
            tableView.deleteRows(at: [indexPath], with: .fade)
        default:
            break
        }
    }
    
    // MARK: アクション
    
    func createTestCaseViewController(testCase: TestCase) -> TestCaseViewController {
        let controller = storyboard!
            .instantiateViewController(withIdentifier: "TestCaseViewController")
            as! TestCaseViewController
        controller.testCase = testCase
        return controller
    }
    
    @IBAction func addNewConfiguration(_ sender: Any) {
        let id = Utilities.randomString()
        let config = Configuration(url: URL(string: "wss:///signaling")!,
                                   channelId: Utilities.randomString(),
                                   role: .publisher)
        let title = "Configuration \(testCases.count+1)"
        let testCase = TestCase(id: id, title: title, configuration: config)
        TestSuiteManager.shared.save { manager in
            manager.add(testCase: testCase)
        }
        tableView.reloadData()
    }
    
}
