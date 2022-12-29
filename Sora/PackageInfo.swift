/// :nodoc:
public enum SDKInfo {
    // Sora iOS SDK のバージョンを定義する
    public static let version = "2022.6.0"
}

/**
 WebRTC フレームワークの情報を表します。
 */
public enum WebRTCInfo {
    /// WebRTC フレームワークのバージョン
    public static let version = "M109"

    /// WebRTC フレームワークのコミットポジション
    public static let commitPosition = "2"

    /// WebRTC フレームワークのメンテナンスバージョン
    public static let maintenanceVersion = "0"

    /// WebRTC フレームワークのソースコードのリビジョン
    public static let revision = "c71b34235eb0f1f8c7cd3b66a01bd003c1299e00"

    /// WebRTC フレームワークのソースコードのリビジョン (短縮版)
    public static var shortRevision: String {
        String(revision[revision.startIndex ..< revision.index(
            revision.startIndex, offsetBy: 7
        )])
    }
}
