/// :nodoc:
public enum SDKInfo {
  // Sora iOS SDK のバージョンを定義する
  public static let version = "2026.4.0"
}

/// WebRTC フレームワークの情報を表します。
public enum WebRTCInfo {
  /// WebRTC フレームワークのバージョン
  public static let version = "M156"

  /// WebRTC の branch-heads
  public static let branch = "8078"

  /// WebRTC フレームワークのコミットポジション
  public static let commitPosition = "5"

  /// WebRTC フレームワークのメンテナンスバージョン
  public static let maintenanceVersion = "1"

  /// WebRTC フレームワークのソースコードのリビジョン
  public static let revision = "2a990ce0ccd00a3ad449f2201a8e5c2dad53177d"

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
