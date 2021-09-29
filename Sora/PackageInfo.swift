/// :nodoc:
public struct SDKInfo {
    // Sora iOS SDK のバージョンを定義する
    public static let version = "2021.2"
}

/**
 WebRTC フレームワークの情報を表します。
 */
public struct WebRTCInfo {
    /// WebRTC フレームワークのバージョン
    public static let version = "M93"
    
    /// WebRTC フレームワークのコミットポジション
    public static let commitPosition = "8"
    
    /// WebRTC フレームワークのメンテナンスバージョン
    public static let maintenanceVersion = "0"
    
    /// WebRTC フレームワークのソースコードのリビジョン
    public static let revision = "25e3fd53a79bfdb2bd647ee3a199eb9c3a71d271"
    
    /// WebRTC フレームワークのソースコードのリビジョン (短縮版)
    public static var shortRevision: String {
        return String(revision[revision.startIndex..<revision.index(
                                revision.startIndex, offsetBy: 7)])
    }
    
}
