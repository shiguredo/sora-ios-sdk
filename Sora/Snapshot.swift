import Foundation
import UIKit
import CoreMedia
import SDWebImage

public struct Snapshot {
    
    public let image: CGImage
    public let timestamp: Date
    
    init(image: CGImage, timestamp: Date) {
        self.image = image
        self.timestamp = timestamp
    }
    
}
