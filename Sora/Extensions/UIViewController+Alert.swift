import Foundation

/**
 :nodoc:
 */
extension UIViewController {
    
    public func showTemporaryAlert(title: String? = nil,
                                   message: String? = nil,
                                   delay: Double? = 0.5,
                                   handler: (() -> Void)? = nil) {
        let dialog = UIAlertController(title: title,
                                       message: message,
                                       preferredStyle: .alert)
        present(dialog, animated: true) {
            let delay = DispatchTime.now() + 0.6
            DispatchQueue.main.asyncAfter(deadline: delay) {
                self.dismiss(animated: true, completion: handler)
            }
        }
    }
    
}
