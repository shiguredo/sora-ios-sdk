/// :nodoc:
public struct SDKInfo {
    // Sora iOS SDK のバージョンを定義する
    public static let version = "2021.2.1"
}

/**
 WebRTC フレームワークの情報を表します。
 */
public struct WebRTCInfo {
    /// WebRTC フレームワークのバージョン
    public static let version = "M95"
    
    /// WebRTC フレームワークのコミットポジション
    public static let commitPosition = "2"
    
    /// WebRTC フレームワークのメンテナンスバージョン
    public static let maintenanceVersion = "2"
    
    /// WebRTC フレームワークのソースコードのリビジョン
    public static let revision = "8d8c0b440022c84386e02cc0c24c053aa7920be1"
    
    /// WebRTC フレームワークのソースコードのリビジョン (短縮版)
    public static var shortRevision: String {
        return String(revision[revision.startIndex..<revision.index(
                                revision.startIndex, offsetBy: 7)])
    }
    
}
