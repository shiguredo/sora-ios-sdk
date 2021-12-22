/// :nodoc:
public enum SDKInfo {
    // Sora iOS SDK のバージョンを定義する
    public static let version = "2021.3.0"
}

/**
 WebRTC フレームワークの情報を表します。
 */
public enum WebRTCInfo {
    /// WebRTC フレームワークのバージョン
    public static let version = "M96"
    
    /// WebRTC フレームワークのコミットポジション
    public static let commitPosition = "2"
    
    /// WebRTC フレームワークのメンテナンスバージョン
    public static let maintenanceVersion = "0"

    /// WebRTC フレームワークのソースコードのリビジョン
    public static let revision = "7ec519c8297828cfcd4c3a3871837ed3008d577e"
    
    /// WebRTC フレームワークのソースコードのリビジョン (短縮版)
    public static var shortRevision: String {
        String(revision[revision.startIndex ..< revision.index(
            revision.startIndex, offsetBy: 7
        )])
    }
}
