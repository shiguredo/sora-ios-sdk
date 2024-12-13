/// :nodoc:
public enum SDKInfo {
    // Sora iOS SDK のバージョンを定義する
    public static let version = "2024.3.0"
}

/**
 WebRTC フレームワークの情報を表します。
 */
public enum WebRTCInfo {
    /// WebRTC フレームワークのバージョン
    public static let version = "M130"

    /// WebRTC の branch-heads
    public static let branch = "6723"

    /// WebRTC フレームワークのコミットポジション
    public static let commitPosition = "2"

    /// WebRTC フレームワークのメンテナンスバージョン
    public static let maintenanceVersion = "0"

    /// WebRTC フレームワークのソースコードのリビジョン
    public static let revision = "28b793b4dd275bf2b901b87e01c0ee8d4f5732fc"

    /// WebRTC フレームワークのソースコードのリビジョン (短縮版)
    public static var shortRevision: String {
        String(revision[revision.startIndex ..< revision.index(
            revision.startIndex, offsetBy: 7
        )])
    }
}
