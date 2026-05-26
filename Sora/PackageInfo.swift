/// :nodoc:
public enum SDKInfo {
  // Sora iOS SDK のバージョンを定義する
  public static let version = "2026.2.0-canary.4"
}

/// WebRTC フレームワークの情報を表します。
public enum WebRTCInfo {
  /// WebRTC フレームワークのバージョン
  public static let version = "M148"

  /// WebRTC の branch-heads
  public static let branch = "7778"

  /// WebRTC フレームワークのコミットポジション
  public static let commitPosition = "7"

  /// WebRTC フレームワークのメンテナンスバージョン
  public static let maintenanceVersion = "0"

  /// WebRTC フレームワークのソースコードのリビジョン
  public static let revision = "9a7f650bcd14f241d20f88f4e1ea3b7300de72ac"

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
