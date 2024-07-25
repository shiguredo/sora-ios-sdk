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
    public static let version = "M127"

    /// WebRTC フレームワークのコミットポジション
    public static let commitPosition = "1"

    /// WebRTC フレームワークのメンテナンスバージョン
    public static let maintenanceVersion = "1"

    /// WebRTC フレームワークのソースコードのリビジョン
    public static let revision = "e0b28a6a81a989c1f5c89e30fcd247870047390d"

    /// WebRTC の branch-heads
    public static let branch = "6433"

    /// WebRTC フレームワークのソースコードのリビジョン (短縮版)
    public static var shortRevision: String {
        String(revision[revision.startIndex ..< revision.index(
            revision.startIndex, offsetBy: 7
        )])
    }
}
