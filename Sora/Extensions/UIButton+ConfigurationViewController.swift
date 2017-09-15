import Foundation

extension UIButton {
    
    public func setTitleOn(_ isOn: Bool,
                    title: String? = nil,
                    isEnabled: Bool = true) {
        if let title = title {
            setTitle(title, for: .normal)
        }
        titleLabel?.setTextOn(isOn)
        self.isEnabled = isEnabled
    }
    
}
