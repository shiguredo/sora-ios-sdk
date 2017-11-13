import Foundation
import UIKit
import CoreMedia
import SDWebImage

/**
 映像のスナップショットです。
 スナップショットを有効にするには、 `Configuration.snapshotEnabled` に `true` をセットします。
 */
public struct Snapshot {
    
    /// スナップショットの画像
    public let image: CGImage
    
    /// スナップショットの生成時刻
    public let timestamp: Date
    
    init(image: CGImage, timestamp: Date) {
        self.image = image
        self.timestamp = timestamp
    }
    
}
