import UIKit

class LogViewController: UIViewController, UISearchBarDelegate, TestCaseControllable {
    
    @IBOutlet weak var logTextView: UITextView!
    
    var testCaseController: TestCaseController!

    override func viewDidLoad() {
        super.viewDidLoad()

        let edit = UIBarButtonItem(title: "Edit",
                                   style: .plain,
                                   target: self,
                                   action: #selector(showEditSheet))
        let top = UIBarButtonItem(title: "Top",
                                  style: .plain,
                                  target: self,
                                  action: #selector(scrollToTop))
        navigationItem.title = "Log"
        navigationItem.rightBarButtonItems = [edit, top]
    }

    override func viewWillAppear(_ animated: Bool) {
        TestSuiteManager.shared.logViewController = self
        reloadData()
        super.viewWillAppear(animated)
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

    func reloadData() {
        logTextView.isScrollEnabled = false
        logTextView.text = TestSuiteManager.shared.logText
        logTextView.isScrollEnabled = true
        let scrollY = logTextView.contentSize.height - logTextView.bounds.height
        let scrollPoint = CGPoint(x: 0, y: scrollY > 0 ? scrollY : 0)
        logTextView.setContentOffset(scrollPoint, animated: false)
    }
    
    @objc func scrollToTop() {
        logTextView.setContentOffset(CGPoint(x: 0, y: 0), animated: true)
    }
    
    @objc func showEditSheet() {
        let sheet = UIAlertController(title: nil,
                                      message: nil,
                                      preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Copy Log",
                                      style: .default)
        { action in
            self.copyLog()
        })
        sheet.addAction(UIAlertAction(title: "Clear Log",
                                      style: .default)
        { action in
            self.clearLog()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(sheet, animated: true)
    }
    
    func copyLog() {
        if let log = logTextView.text {
            UIPasteboard.general.setValue(log, forPasteboardType: "TestSweets")
            showTemporaryAlert(title: "Copied")
        }
    }
    
    func clearLog() {
        TestSuiteManager.shared.clearLogText()
        logTextView.text = ""
    }
    
}
