import Foundation
import UIKit
import CoreMedia
import SDWebImage

public class Snapshot {
    
    public var image: CGImage
    public var timestamp: Date
    
    init(image: CGImage, timestamp: Date) {
        self.image = image
        self.timestamp = timestamp
    }
    
}
