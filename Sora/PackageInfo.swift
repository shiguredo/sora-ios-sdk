/// :nodoc:
public enum SDKInfo {
  // Sora iOS SDK のバージョンを定義する
  public static let version = "2025.2.0-canary.4"
}

/// WebRTC フレームワークの情報を表します。
public enum WebRTCInfo {
  /// WebRTC フレームワークのバージョン
  public static let version = "M138"

  /// WebRTC の branch-heads
  public static let branch = "7204"

  /// WebRTC フレームワークのコミットポジション
  public static let commitPosition = "0"

  /// WebRTC フレームワークのメンテナンスバージョン
  public static let maintenanceVersion = "3"

  /// WebRTC フレームワークのソースコードのリビジョン
  public static let revision = "e4445e46a910eb407571ec0b0b8b7043562678cf"

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
