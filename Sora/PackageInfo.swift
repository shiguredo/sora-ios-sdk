/// :nodoc:
public enum SDKInfo {
    // Sora iOS SDK のバージョンを定義する
    public static let version = "2022.1.0"
}

/**
 WebRTC フレームワークの情報を表します。
 */
public enum WebRTCInfo {
    /// WebRTC フレームワークのバージョン
    public static let version = "M99"

    /// WebRTC フレームワークのコミットポジション
    public static let commitPosition = "1"

    /// WebRTC フレームワークのメンテナンスバージョン
    public static let maintenanceVersion = "0"

    /// WebRTC フレームワークのソースコードのリビジョン
    public static let revision = "81f4af57823c28c903b61b273e6fc2b87787b11b"

    /// WebRTC フレームワークのソースコードのリビジョン (短縮版)
    public static var shortRevision: String {
        String(revision[revision.startIndex ..< revision.index(
            revision.startIndex, offsetBy: 7
        )])
    }
}
