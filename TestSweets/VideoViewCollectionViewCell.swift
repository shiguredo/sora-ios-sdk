import UIKit
import Sora

class VideoViewCollectionViewCell: UICollectionViewCell {
    
    @IBOutlet weak var videoView: VideoView!
    
    var stream: MediaStream? {
        didSet {
            stream?.videoRenderer = videoView
        }
    }
    
}
