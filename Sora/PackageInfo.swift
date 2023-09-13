/// :nodoc:
public enum SDKInfo {
    // Sora iOS SDK のバージョンを定義する
    public static let version = "2023.3.0"
}

/**
 WebRTC フレームワークの情報を表します。
 */
public enum WebRTCInfo {
    /// WebRTC フレームワークのバージョン
    public static let version = "M116"

    /// WebRTC フレームワークのコミットポジション
    public static let commitPosition = "6"

    /// WebRTC フレームワークのメンテナンスバージョン
    public static let maintenanceVersion = "1"

    /// WebRTC フレームワークのソースコードのリビジョン
    public static let revision = "44bc8e96ed88005fec89a1cc479e291fea30d1b3"

    /// WebRTC フレームワークのソースコードのリビジョン (短縮版)
    public static var shortRevision: String {
        String(revision[revision.startIndex ..< revision.index(
            revision.startIndex, offsetBy: 7
        )])
    }
}
