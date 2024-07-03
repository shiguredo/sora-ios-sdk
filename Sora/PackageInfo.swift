/// :nodoc:
public enum SDKInfo {
    // Sora iOS SDK のバージョンを定義する
    public static let version = "2024.2.0"
}

/**
 WebRTC フレームワークの情報を表します。
 */
public enum WebRTCInfo {
    /// WebRTC フレームワークのバージョン
    public static let version = "M125"

    /// WebRTC フレームワークのコミットポジション
    public static let commitPosition = "2"

    /// WebRTC フレームワークのメンテナンスバージョン
    public static let maintenanceVersion = "5"

    /// WebRTC フレームワークのソースコードのリビジョン
    public static let revision = "8505a9838ea91c66c96c173d30cd66f9dbcc7548"

    /// WebRTC の branch-heads
    public static let branch = "6422"

    /// WebRTC フレームワークのソースコードのリビジョン (短縮版)
    public static var shortRevision: String {
        String(revision[revision.startIndex ..< revision.index(
            revision.startIndex, offsetBy: 7
        )])
    }
}
