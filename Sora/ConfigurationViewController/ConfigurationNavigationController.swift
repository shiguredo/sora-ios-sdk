import UIKit

class ConfigurationNavigationController: UINavigationController,
    UINavigationControllerDelegate,
    ConfigurationViewControllable {
    
    weak var configurationViewController: ConfigurationViewController?
    
    override func viewDidLoad() {
        super.viewDidLoad()

        delegate = self
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

    func navigationController(_ navigationController: UINavigationController,
                              willShow viewController: UIViewController,
                              animated: Bool) {
        if let vc = viewController as? ConfigurationViewControllable {
            vc.configurationViewController = configurationViewController
        }
    }

}
