import Foundation

@available(*, unavailable, message: "このクラスは廃止予定です。廃止後も利用したい場合はこのクラス定義をご自身のソースに組み込んで利用してください。")
public class MediaChannelConfiguration {
    public static var maxBitRate = 5000

    public var connectionMetadata: String?
    public var connectionTimeout: Int = 30
    public var multistreamEnabled: Bool = false
    public var videoCodec: VideoCodec = .default
    public var audioCodec: AudioCodec = .default
    public var videoEnabled: Bool = true
    public var audioEnabled: Bool = true
    public var snapshotEnabled: Bool = false

    // TODO:

    // TODO: RTCConfiguration
}
