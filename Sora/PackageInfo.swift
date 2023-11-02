/// :nodoc:
public enum SDKInfo {
    // Sora iOS SDK のバージョンを定義する
    public static let version = "2023.3.1"
}

/**
 WebRTC フレームワークの情報を表します。
 */
public enum WebRTCInfo {
    /// WebRTC フレームワークのバージョン
    public static let version = "M119"

    /// WebRTC フレームワークのコミットポジション
    public static let commitPosition = "2"

    /// WebRTC フレームワークのメンテナンスバージョン
    public static let maintenanceVersion = "1"

    /// WebRTC フレームワークのソースコードのリビジョン
    public static let revision = "52bc9f7c1205f4b731ea0289b059f7d240c1e228"

    /// WebRTC フレームワークのソースコードのリビジョン (短縮版)
    public static var shortRevision: String {
        String(revision[revision.startIndex ..< revision.index(
            revision.startIndex, offsetBy: 7
        )])
    }
}
