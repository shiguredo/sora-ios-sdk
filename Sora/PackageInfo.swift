/// :nodoc:
public enum SDKInfo {
    // Sora iOS SDK のバージョンを定義する
    public static let version = "2024.1.0"
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
}
