/// :nodoc:
public enum SDKInfo {
  // Sora iOS SDK のバージョンを定義する
  public static let version = "2025.3.0-canary.0"
}

/// WebRTC フレームワークの情報を表します。
public enum WebRTCInfo {
  /// WebRTC フレームワークのバージョン
  public static let version = "M143"

  /// WebRTC の branch-heads
  public static let branch = "7499"

  /// WebRTC フレームワークのコミットポジション
  public static let commitPosition = "1"

  /// WebRTC フレームワークのメンテナンスバージョン
  public static let maintenanceVersion = "0"

  /// WebRTC フレームワークのソースコードのリビジョン
  public static let revision = "a5751574a386ba0ba80b8c62201977f6aab6c225"

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
