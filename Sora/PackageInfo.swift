/// :nodoc:
public enum SDKInfo {
  // Sora iOS SDK のバージョンを定義する
  public static let version = "2026.3.0"
}

/// WebRTC フレームワークの情報を表します。
public enum WebRTCInfo {
  /// WebRTC フレームワークのバージョン
  public static let version = "M155"

  /// WebRTC の branch-heads
  public static let branch = "8059"

  /// WebRTC フレームワークのコミットポジション
  public static let commitPosition = "1"

  /// WebRTC フレームワークのメンテナンスバージョン
  public static let maintenanceVersion = "0"

  /// WebRTC フレームワークのソースコードのリビジョン
  public static let revision = "c4f21b1f91386bae6d710540976dff5aae67b3c5"

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
