import AVFoundation
import CryptoKit
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
  private struct InvalidJSONError: Error {}

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

  /// E2E テスト用の HS256 JWT を生成する
  ///
  /// private claims を付与した access token が必要なテストから利用する。
  /// channel_id は引数の値で必ず上書きされる (privateClaims に含めても無視される)。
  internal func buildJWTAccessToken(
    channelId: String,
    privateClaims: [String: Any] = [:]
  ) throws -> String {
    // buildConfiguration と同じガードを意図的に維持する。
    // 本ヘルパーは buildConfiguration を通らない単独利用も想定しており、ガードが無いと
    // 空キーで HMAC 署名され「接続に失敗した」という不可解なエラーになる
    guard
      let secretKey = ProcessInfo.processInfo.environment["TEST_SECRET_KEY"],
      !secretKey.isEmpty
    else {
      throw XCTSkip("TEST_SECRET_KEY が未設定のためスキップします")
    }

    let header: [String: Any] = [
      "alg": "HS256",
      "typ": "JWT",
    ]
    var payload = privateClaims
    payload["channel_id"] = channelId

    let headerData = try jsonData(header)
    let payloadData = try jsonData(payload)
    let headerPart = base64URLEncoded(headerData)
    let payloadPart = base64URLEncoded(payloadData)
    let signingInput = "\(headerPart).\(payloadPart)"
    let key = SymmetricKey(data: Data(secretKey.utf8))
    let signature = HMAC<SHA256>.authenticationCode(
      for: Data(signingInput.utf8),
      using: key)

    return "\(signingInput).\(base64URLEncoded(Data(signature)))"
  }

  /// チャンネルを切断し、正常切断コード (1000) が onDisconnect で通知されることを確認する
  ///
  /// 切断済みのチャンネルでは onDisconnect が発火しないため、その場合は何もせずに戻る。
  /// `.disconnecting` は PeerChannel の後始末中なので、完了通知を待つ。
  internal func disconnectAndVerify(channel: MediaChannel, timeout: TimeInterval = 10) {
    guard channel.state != .disconnected else {
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
    // シグナリング受信による切断完了が state チェックとハンドラ設定の間に入った場合は
    // onDisconnect が発火済みのため、wait せずに戻る
    guard channel.state != .disconnected else {
      return
    }
    if channel.state != .disconnecting {
      channel.disconnect(error: nil)
    }
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
      guard channel.state != .disconnected else { continue }
      let disconnectExpectation = self.expectation(description: "切断が完了すること")
      channel.handlers.onDisconnect = { _ in
        disconnectExpectation.fulfill()
      }
      // シグナリング受信による切断が state チェックとハンドラ設定の間に入った場合は
      // onDisconnect が発火済みのため、待たずにスキップする
      guard channel.state != .disconnected else { continue }
      if channel.state != .disconnecting {
        channel.disconnect(error: nil)
      }
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

  /// outbound-rtp (video) の rid ごとの送信量と scalabilityMode を返す
  internal func simulcastOutboundVideoStats(stats: Statistics) -> [(
    rid: String, bytesSent: Int, packetsSent: Int, scalabilityMode: String
  )] {
    stats.entries.compactMap { entry in
      guard entry.type == "outbound-rtp",
        (entry.values["kind"] as? NSString) == "video",
        let rid = entry.values["rid"] as? String
      else {
        return nil
      }
      return (
        rid: rid,
        bytesSent: (entry.values["bytesSent"] as? NSNumber)?.intValue ?? 0,
        packetsSent: (entry.values["packetsSent"] as? NSNumber)?.intValue ?? 0,
        scalabilityMode: (entry.values["scalabilityMode"] as? String) ?? ""
      )
    }
  }

  /// JSON オブジェクトを Data に変換する
  ///
  /// data(withJSONObject:) は JSON 化できない値 (Date / NaN 等) を渡すと NSException
  /// (NSInvalidArgumentException) でプロセスが終了する (Swift の do-catch では捕まえられない)。
  /// 事前の isValidJSONObject チェックで検出し、クラッシュではなくテスト失敗に変換する
  private func jsonData(_ object: [String: Any]) throws -> Data {
    guard JSONSerialization.isValidJSONObject(object) else {
      XCTFail("JWT ペイロードに JSON 化できない値が含まれている")
      throw InvalidJSONError()
    }
    return try JSONSerialization.data(withJSONObject: object)
  }

  /// Base64URL 形式へエンコードする
  private func base64URLEncoded(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
