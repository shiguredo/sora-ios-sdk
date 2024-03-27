/// :nodoc:
public enum SDKInfo {
    /// Sora iOS SDK のバージョンを定義する
    public static let version = "2024.1.0"
    /// Sora iOS SDK のバージョン文字列
    public static let versionString = "Sora iOS SDK \(version)"
}

/**
 WebRTC フレームワークの情報を表します。
 */
public enum WebRTCInfo {
    /// WebRTC フレームワークのバージョン
    public static let version = "M123"

    /// WebRTC フレームワークのコミットポジション
    public static let commitPosition = "3"

    /// WebRTC フレームワークのメンテナンスバージョン
    public static let maintenanceVersion = "0"

    /// WebRTC フレームワークのソースコードのリビジョン
    public static let revision = "41b1493ddb5d98e9125d5cb002fd57ce76ebd8a7"

    /// WebRTC フレームワークのソースコードのリビジョン (短縮版)
    public static var shortRevision: String {
        String(revision[revision.startIndex ..< revision.index(
            revision.startIndex, offsetBy: 7
        )])
    }

    /// WebRTC の branch-heads
    public static let branchHeads = "6312"

    ///  libwebrtc のバージョン文字列 例) "Shiguredo-build M123 (M123.6312.3.0 41b1493)"
    public static let versionString = "Shiguredo-build \(version) (\(String(version.dropFirst())).\(branchHeads).\(commitPosition).\(maintenanceVersion) \(shortRevision))"
}
