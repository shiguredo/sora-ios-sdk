import Foundation
import UIKit

extension UITextField {
    
    public func nonEmptyText() -> String? {
        if let text = text {
            if !text.isEmpty {
                return text
            }
        }
        return nil
    }
    
}
