import Foundation

// ストリームのレンダラーとしてセットする
public class VideoStreamInputNode: VideoInputNode {
    public weak var stream: MediaStream?
}

// extension VideoStreamInputNode: VideoRenderer {}
