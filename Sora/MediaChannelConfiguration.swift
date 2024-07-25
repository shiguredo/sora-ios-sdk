import Foundation

// TODO(zztkm): MediaChannelConfiguration は現在利用されていないため、不要かもしれない
public class MediaChannelConfiguration {
    public static var maxBitRate = 5000

    public var connectionMetadata: String?
    public var connectionTimeout: Int = 30
    @available(*, deprecated, message: "レガシーストリーム機能は 2025 年 6 月リリースの Sora にて廃止します。")
    public var multistreamEnabled: Bool = false
    public var videoCodec: VideoCodec = .default
    public var audioCodec: AudioCodec = .default
    public var videoEnabled: Bool = true
    public var audioEnabled: Bool = true
    public var snapshotEnabled: Bool = false

    // TODO:

    // TODO: RTCConfiguration
}
