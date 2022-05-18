/// :nodoc:
public enum SDKInfo {
    // Sora iOS SDK のバージョンを定義する
    public static let version = "2022.2.1"
}

/**
 WebRTC フレームワークの情報を表します。
 */
public enum WebRTCInfo {
    /// WebRTC フレームワークのバージョン
    public static let version = "M102"

    /// WebRTC フレームワークのコミットポジション
    public static let commitPosition = "7"

    /// WebRTC フレームワークのメンテナンスバージョン
    public static let maintenanceVersion = "1"

    /// WebRTC フレームワークのソースコードのリビジョン
    public static let revision = "6ff73180ad01aca444c9856f91148eb2b948ce63"

    /// WebRTC フレームワークのソースコードのリビジョン (短縮版)
    public static var shortRevision: String {
        String(revision[revision.startIndex ..< revision.index(
            revision.startIndex, offsetBy: 7
        )])
    }
}
