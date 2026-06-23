/// :nodoc:
public enum SDKInfo {
  // Sora iOS SDK のバージョンを定義する
  public static let version = "2026.2.0-canary.4"
}

/// WebRTC フレームワークの情報を表します。
public enum WebRTCInfo {
  /// WebRTC フレームワークのバージョン
  public static let version = "M150"

  /// WebRTC の branch-heads
  public static let branch = "7871"

  /// WebRTC フレームワークのコミットポジション
  public static let commitPosition = "2"

  /// WebRTC フレームワークのメンテナンスバージョン
  public static let maintenanceVersion = "1"

  /// WebRTC フレームワークのソースコードのリビジョン
  public static let revision = "b515dc61f55c8cfa1ea6e315651fb61d99bfa877"

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
