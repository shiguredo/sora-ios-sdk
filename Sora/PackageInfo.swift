/// :nodoc:
public enum SDKInfo {
  // Sora iOS SDK のバージョンを定義する
  public static let version = "2026.1.0-canary.7"
}

/// WebRTC フレームワークの情報を表します。
public enum WebRTCInfo {
  /// WebRTC フレームワークのバージョン
  public static let version = "M144"

  /// WebRTC の branch-heads
  public static let branch = "7559"

  /// WebRTC フレームワークのコミットポジション
  public static let commitPosition = "2"

  /// WebRTC フレームワークのメンテナンスバージョン
  public static let maintenanceVersion = "1"

  /// WebRTC フレームワークのソースコードのリビジョン
  public static let revision = "8f3537ef5b85b4c7dabed2676d4b72214c69c494"

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
