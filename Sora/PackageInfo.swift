/// :nodoc:
public enum SDKInfo {
  // Sora iOS SDK のバージョンを定義する
  public static let version = "2026.3.0"
}

/// WebRTC フレームワークの情報を表します。
public enum WebRTCInfo {
  /// WebRTC フレームワークのバージョン
  public static let version = "M154"

  /// WebRTC の branch-heads
  public static let branch = "8037"

  /// WebRTC フレームワークのコミットポジション
  public static let commitPosition = "1"

  /// WebRTC フレームワークのメンテナンスバージョン
  public static let maintenanceVersion = "2"

  /// WebRTC フレームワークのソースコードのリビジョン
  public static let revision = "c2b761bb73f0b2ced096274abb415f6c7559a28b"

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
