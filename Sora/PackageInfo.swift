/// :nodoc:
public enum SDKInfo {
  // Sora iOS SDK のバージョンを定義する
  public static let version = "2025.3.0-canary.0"
}

/// WebRTC フレームワークの情報を表します。
public enum WebRTCInfo {
  /// WebRTC フレームワークのバージョン
  public static let version = "M140"

  /// WebRTC の branch-heads
  public static let branch = "7204"

  /// WebRTC フレームワークのコミットポジション
  public static let commitPosition = "2"

  /// WebRTC フレームワークのメンテナンスバージョン
  public static let maintenanceVersion = "2"

  /// WebRTC フレームワークのソースコードのリビジョン
  public static let revision = "36ea4535a500ac137dbf1f577ce40dc1aaa774ef"

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
