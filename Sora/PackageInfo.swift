/// :nodoc:
public enum SDKInfo {
  // Sora iOS SDK のバージョンを定義する
  public static let version = "2026.2.0-canary.3"
}

/// WebRTC フレームワークの情報を表します。
public enum WebRTCInfo {
  /// WebRTC フレームワークのバージョン
  public static let version = "M146"

  /// WebRTC の branch-heads
  public static let branch = "7680"

  /// WebRTC フレームワークのコミットポジション
  public static let commitPosition = "0"

  /// WebRTC フレームワークのメンテナンスバージョン
  public static let maintenanceVersion = "1"

  /// WebRTC フレームワークのソースコードのリビジョン
  public static let revision = "d1972add2a63b2a528a6471d447f82e0010b5215"

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
