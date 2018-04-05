import Foundation

/// :nodoc:
extension UITextField {
    
    public func setTextOn(_ flag: Bool) {
        textColor = flag ? UIColor.darkText : UIColor.lightGray
        isEnabled = flag
    }
    
}

