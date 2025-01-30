/// :nodoc:
public enum SDKInfo {
    // Sora iOS SDK のバージョンを定義する
    public static let version = "2025.2.0-canary.1"
}

/**
 WebRTC フレームワークの情報を表します。
 */
public enum WebRTCInfo {
    /// WebRTC フレームワークのバージョン
    public static let version = "M132"

    /// WebRTC の branch-heads
    public static let branch = "6834"

    /// WebRTC フレームワークのコミットポジション
    public static let commitPosition = "5"

    /// WebRTC フレームワークのメンテナンスバージョン
    public static let maintenanceVersion = "3"

    /// WebRTC フレームワークのソースコードのリビジョン
    public static let revision = "afaf497805cbb502da89991c2dcd783201efdd08"

    /// WebRTC フレームワークのソースコードのリビジョン (短縮版)
    public static var shortRevision: String {
        String(revision[revision.startIndex ..< revision.index(
            revision.startIndex, offsetBy: 7
        )])
    }
}
