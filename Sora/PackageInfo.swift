/// :nodoc:
public enum SDKInfo {
  // Sora iOS SDK のバージョンを定義する
  public static let version = "2025.2.0-canary.1"
}

/// WebRTC フレームワークの情報を表します。
public enum WebRTCInfo {
  /// WebRTC フレームワークのバージョン
  public static let version = "M133"

  /// WebRTC の branch-heads
  public static let branch = "6943"

  /// WebRTC フレームワークのコミットポジション
  public static let commitPosition = "4"

  /// WebRTC フレームワークのメンテナンスバージョン
  public static let maintenanceVersion = "0"

  /// WebRTC フレームワークのソースコードのリビジョン
  public static let revision = "cd3e2951ff0f36fa12bea747862c52533a2b39f3"

  /// WebRTC フレームワークのソースコードのリビジョン (短縮版)
  public static var shortRevision: String {
    String(
      revision[
        revision
          .startIndex..<revision.index(
            revision.startIndex, offsetBy: 7
          )])
  }
}
