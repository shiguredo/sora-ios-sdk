/// :nodoc:
public enum SDKInfo {
  // Sora iOS SDK のバージョンを定義する
  public static let version = "2025.2.0-canary.3"
}

/// WebRTC フレームワークの情報を表します。
public enum WebRTCInfo {
  /// WebRTC フレームワークのバージョン
  public static let version = "M137"

  /// WebRTC の branch-heads
  public static let branch = "7151"

  /// WebRTC フレームワークのコミットポジション
  public static let commitPosition = "3"

  /// WebRTC フレームワークのメンテナンスバージョン
  public static let maintenanceVersion = "1"

  /// WebRTC フレームワークのソースコードのリビジョン
  public static let revision = "cec4daea7ed5da94fc38d790bd12694c86865447"

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
