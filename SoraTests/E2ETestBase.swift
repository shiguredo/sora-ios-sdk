import AVFoundation
import XCTest

@testable @preconcurrency import Sora

/// iOS E2E テストのベースクラス
///
/// 環境変数 SORA_SIGNALING_URL と TEST_SECRET_KEY が未設定の場合はスキップされる。
///
/// 必要な環境変数:
/// - SORA_SIGNALING_URL: Sora シグナリング接続先 URL
/// - TEST_SECRET_KEY: metadata.access_token に設定する認証トークン
/// - TEST_CHANNEL_ID_PREFIX: channelId の prefix (省略可、デフォルト "")
/// - TEST_CHANNEL_ID_SUFFIX: channelId の suffix (省略可、デフォルト "")
/// main queue に束ねた処理からテストメソッドの状態へ安全にアクセスするため、
/// テストクラスは @MainActor で隔離する (サブクラスに継承される)
@MainActor
class E2ETestBase: XCTestCase {
  internal var sora: Sora?
  private var originalLogLevel: LogLevel?
  private var originalAudioCategory: AVAudioSession.Category?
  private var originalAudioMode: AVAudioSession.Mode?
  private var originalAudioOptions: AVAudioSession.CategoryOptions?
  // テストが AVAudioSession を変更したかどうか (ダミー音声テストのみ true になる)。
  // tearDown で「このテストが変更した場合のみ」カテゴリ設定を復元するためのフラグ。
  // AVAudioSession に触れない他の E2E テストに影響しないよう、フラグで限定する
  internal var audioSessionActivatedByTest = false
  private struct InvalidURLError: Error {}

  override func setUp() {
    super.setUp()
    originalLogLevel = Logger.shared.level
    Logger.shared.level = .warn
    // ダミー音声テストが AVAudioSession を変更するため、tearDown で復元できるように保存する
    let session = AVAudioSession.sharedInstance()
    originalAudioCategory = session.category
    originalAudioMode = session.mode
    originalAudioOptions = session.categoryOptions
    audioSessionActivatedByTest = false
    sora = Sora()
  }

  override func tearDown() {
    for channel in sora?.mediaChannels ?? [] {
      channel.disconnect(error: nil)
    }
    sora = nil
    Logger.shared.level = originalLogLevel ?? .info
    // テストが AVAudioSession を変更した場合のみ、カテゴリ設定を復元する。
    // active 状態は取得 API がないため復元できない。setActive(false) を呼ぶと、
    // テスト開始時点で active だった場合に非 active へ落としてしまうため、呼ばない
    if audioSessionActivatedByTest {
      if let category = originalAudioCategory {
        try? AVAudioSession.sharedInstance().setCategory(
          category,
          mode: originalAudioMode ?? .default,
          options: originalAudioOptions ?? [])
      }
    }
    super.tearDown()
  }

  // MARK: - ヘルパー

  /// E2E テスト用のチャンネル ID を構築する
  ///
  /// TEST_CHANNEL_ID_PREFIX / TEST_CHANNEL_ID_SUFFIX 環境変数を組み合わせる。
  /// unique が true の場合は残留接続と混在しない一意な ID にする
  internal func buildChannelId(unique: Bool = false) -> String {
    let prefix = ProcessInfo.processInfo.environment["TEST_CHANNEL_ID_PREFIX"] ?? ""
    let suffix = ProcessInfo.processInfo.environment["TEST_CHANNEL_ID_SUFFIX"] ?? ""
    let middle = unique ? "e2e-test-\(UUID().uuidString)" : "e2e-test"
    return "\(prefix)\(middle)\(suffix)"
  }

  /// E2E 用の Configuration を構築する
  ///
  /// 環境変数が未設定の場合は XCTSkip でテストをスキップする
  internal func buildConfiguration() throws -> Configuration {
    guard
      let urlString = ProcessInfo.processInfo.environment["SORA_SIGNALING_URL"],
      !urlString.isEmpty
    else {
      throw XCTSkip("SORA_SIGNALING_URL が未設定のためスキップします")
    }
    guard let url = URL(string: urlString) else {
      XCTFail("SORA_SIGNALING_URL が不正な値です: \(urlString)")
      throw InvalidURLError()
    }

    guard
      let accessToken = ProcessInfo.processInfo.environment["TEST_SECRET_KEY"],
      !accessToken.isEmpty
    else {
      throw XCTSkip("TEST_SECRET_KEY が未設定のためスキップします")
    }

    let channelId = buildChannelId()

    // E2E テスト専用のメタデータ構造体
    struct E2EMetadata: Encodable {
      // swift-format-ignore: AlwaysUseLowerCamelCase
      let access_token: String
    }

    var config = Configuration(
      urlCandidates: [url],
      channelId: channelId,
      role: .recvonly
    )
    config.signalingConnectMetadata = E2EMetadata(access_token: accessToken)

    return config
  }

  /// `role` を指定して E2E 用の Configuration を構築する
  internal func buildConfiguration(role: Role) throws -> Configuration {
    var config = try buildConfiguration()
    config.role = role
    return config
  }

  /// チャンネルを切断し、正常切断コード (1000) が onDisconnect で通知されることを確認する
  ///
  /// 切断済みのチャンネルでは onDisconnect が発火しない (MediaChannel.internalDisconnect は
  /// .disconnecting / .disconnected 状態では何もせずに戻る) ため、その場合は何もせずに戻る
  internal func disconnectAndVerify(channel: MediaChannel, timeout: TimeInterval = 10) {
    guard !channel.state.isDisconnected else {
      return
    }
    let disconnectExpectation = self.expectation(description: "切断が完了すること")
    channel.handlers.onDisconnect = { event in
      if case .ok(let code, _) = event {
        XCTAssertEqual(code, 1000, "正常切断コードであること")
      } else {
        XCTFail("予期しない切断: \(event)")
      }
      disconnectExpectation.fulfill()
    }
    // シグナリング受信による切断が state チェックとハンドラ設定の間に入った場合は
    // onDisconnect が発火済みのため、wait せずに戻る
    guard !channel.state.isDisconnected else {
      return
    }
    channel.disconnect(error: nil)
    wait(for: [disconnectExpectation], timeout: timeout)
  }

  /// 接続済みチャンネルの切断を完了まで待つ
  ///
  /// (切断が完了する前にテストが終了して、残留チャンネルの onDisconnect が次のテストに
  /// 発火しないようにする)
  internal func disconnectAll(channels: [MediaChannel?]) {
    for channel in channels {
      guard let channel else { continue }
      // 切断済みのチャンネルでは onDisconnect が発火しないため、待たずにスキップする
      guard !channel.state.isDisconnected else { continue }
      let disconnectExpectation = self.expectation(description: "切断が完了すること")
      channel.handlers.onDisconnect = { _ in
        disconnectExpectation.fulfill()
      }
      // シグナリング受信による切断が state チェックとハンドラ設定の間に入った場合は
      // onDisconnect が発火済みのため、待たずにスキップする
      guard !channel.state.isDisconnected else { continue }
      channel.disconnect(error: nil)
      self.wait(for: [disconnectExpectation], timeout: 10)
    }
  }

  /// inbound-rtp (video) の bytesReceived / packetsReceived を返す (存在しない場合は 0)
  internal func inboundVideoByteCounts(stats: Statistics?) -> (
    bytesReceived: Int, packetsReceived: Int
  ) {
    let inbound = stats?.entries.first {
      $0.type == "inbound-rtp"
        && ($0.values["kind"] as? NSString) == "video"
    }
    return (
      bytesReceived: (inbound?.values["bytesReceived"] as? NSNumber)?.intValue ?? 0,
      packetsReceived: (inbound?.values["packetsReceived"] as? NSNumber)?.intValue ?? 0
    )
  }

  /// inbound-rtp (video) の bytesReceived / packetsReceived が 0 より大きいかを確認する
  internal func hasInboundVideo(stats: Statistics) -> Bool {
    let counts = inboundVideoByteCounts(stats: stats)
    return counts.bytesReceived > 0 && counts.packetsReceived > 0
  }
}
