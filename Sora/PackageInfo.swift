/// :nodoc:
public enum SDKInfo {
  // Sora iOS SDK のバージョンを定義する
  public static let version = "2026.2.0-canary.5"
}

/// WebRTC フレームワークの情報を表します。
public enum WebRTCInfo {
  /// WebRTC フレームワークのバージョン
  public static let version = "M150"

  /// WebRTC の branch-heads
  public static let branch = "7871"

  /// WebRTC フレームワークのコミットポジション
  public static let commitPosition = "3"

  /// WebRTC フレームワークのメンテナンスバージョン
  public static let maintenanceVersion = "0"

  /// WebRTC フレームワークのソースコードのリビジョン
  public static let revision = "1f975dfd761af6e5d76d28333191973b258d82a8"

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
