import UIKit

class MainNavigationViewController: UINavigationController, UINavigationControllerDelegate {

    override func viewDidLoad() {
        super.viewDidLoad()

        // Do any additional setup after loading the view.
        delegate = self
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

    func navigationController(_ navigationController: UINavigationController,
                              willShow viewController: UIViewController, animated: Bool) {
        if let main = viewController as? MainViewController {
            for testCase in main.testCaseControllers {
                if let chan = testCase.mediaChannel {
                    switch chan.state {
                    case .disconnecting, .disconnected:
                        break
                    default:
                        if !testCase.viewController!.keepsConnection {
                            chan.disconnect(error: nil)
                            showTemporaryAlert(title: "Connection disconnected",
                                               message: testCase.testCase.title)
                        }
                    }
                }
            }
        }
    }
    
}
