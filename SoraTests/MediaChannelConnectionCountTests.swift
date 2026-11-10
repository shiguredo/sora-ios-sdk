import Foundation
import XCTest

@testable import Sora

/// `MediaChannel` の接続人数の導出と読み書きの対応を検証します。
///
/// 並行読み書きは `ConcurrencyStressTests.testConnectionCountsReadWriteRace` が TSan 有効で
/// 検証します。このファイルは、そこでは検出できない値の対応関係 (notify の 4 値からの導出、
/// getter と保持領域の対応) を単体で検証します。モックやスタブは使用しません。
final class MediaChannelConnectionCountTests: XCTestCase {
  /// `type: notify` の JSON を実 `Signaling.decode` で復号します。
  private func decodeNotify(_ json: String) throws -> Signaling {
    try Signaling.decode(Data(json.utf8)).get()
  }

  /// JSON から指定したキーを除いた文字列を返します。
  private func removeJSONField(_ key: String, from json: String) throws -> String {
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    var removed = object
    removed.removeValue(forKey: key)
    let data = try JSONSerialization.data(withJSONObject: removed)
    return try XCTUnwrap(String(data: data, encoding: .utf8))
  }

  /// `.notify` の 4 値から 3 つの接続人数が導出され、getter に反映されることを確認します。
  func testHandleSignalingNotifyUpdatesConnectionCounts() throws {
    let mediaChannel = try makeTestMediaChannel()
    // connectionCount が内訳の和ではなくサーバー値のコピーであることを区別するため、
    // あえて channel_connections を内訳の合計と一致しない値にする。
    let signaling = try decodeNotify(
      """
      {
        "type": "notify",
        "event_type": "connection.created",
        "channel_connections": 3,
        "channel_sendonly_connections": 1,
        "channel_recvonly_connections": 2,
        "channel_sendrecv_connections": 4
      }
      """)
    mediaChannel.handleSignaling(signaling)
    XCTAssertEqual(mediaChannel.connectionCount, 3, "connectionCount がそのまま反映されること")
    XCTAssertEqual(
      mediaChannel.publisherCount, 5, "publisherCount が sendonly + sendrecv になること")
    XCTAssertEqual(
      mediaChannel.subscriberCount, 6, "subscriberCount が recvonly + sendrecv になること")
  }

  /// `channel_sendrecv_connections` が欠けている場合は更新しないことを確認します。
  func testHandleSignalingNotifyWithMissingFieldDoesNotUpdate() throws {
    let mediaChannel = try makeTestMediaChannel()
    mediaChannel.updateConnectionCounts(
      connectionCount: 1, publisherCount: 2, subscriberCount: 3)

    // channel_sendrecv_connections を欠落させる。
    let signaling = try decodeNotify(
      """
      {
        "type": "notify",
        "event_type": "connection.created",
        "channel_connections": 10,
        "channel_sendonly_connections": 20,
        "channel_recvonly_connections": 30
      }
      """)
    mediaChannel.handleSignaling(signaling)
    XCTAssertEqual(mediaChannel.connectionCount, 1, "4 値が揃わない notify では更新しないこと")
    XCTAssertEqual(mediaChannel.publisherCount, 2, "4 値が揃わない notify では更新しないこと")
    XCTAssertEqual(mediaChannel.subscriberCount, 3, "4 値が揃わない notify では更新しないこと")
  }

  /// `.notify` の受信が既存の `onReceiveSignaling` handler へ転送されることを確認します。
  func testHandleSignalingForwardsToHandler() throws {
    let mediaChannel = try makeTestMediaChannel()
    var received: Signaling?
    mediaChannel.internalHandlers.onReceiveSignaling = { received = $0 }
    let signaling = try decodeNotify(
      """
      {
        "type": "notify",
        "event_type": "connection.created",
        "channel_connections": 1,
        "channel_sendonly_connections": 1,
        "channel_recvonly_connections": 0,
        "channel_sendrecv_connections": 0
      }
      """)
    mediaChannel.handleSignaling(signaling)

    guard let received else {
      XCTFail("internalHandlers.onReceiveSignaling に転送されること")
      return
    }
    guard case .notify = received else {
      XCTFail("notify がそのまま転送されること")
      return
    }
  }

  /// `updateConnectionCounts` の引数と 3 つの getter の対応を確認します。
  func testUpdateConnectionCountsMapping() throws {
    let mediaChannel = try makeTestMediaChannel()
    mediaChannel.updateConnectionCounts(
      connectionCount: 1, publisherCount: 2, subscriberCount: 3)
    XCTAssertEqual(mediaChannel.connectionCount, 1, "connectionCount に 1 が入ること")
    XCTAssertEqual(mediaChannel.publisherCount, 2, "publisherCount に 2 が入ること")
    XCTAssertEqual(mediaChannel.subscriberCount, 3, "subscriberCount に 3 が入ること")

    mediaChannel.updateConnectionCounts(
      connectionCount: 4, publisherCount: 5, subscriberCount: 6)
    XCTAssertEqual(mediaChannel.connectionCount, 4, "connectionCount が上書きされること")
    XCTAssertEqual(mediaChannel.publisherCount, 5, "publisherCount が上書きされること")
    XCTAssertEqual(mediaChannel.subscriberCount, 6, "subscriberCount が上書きされること")
  }

  /// 4 値のいずれかが欠けている notify は導出しないことを確認します。
  func testConnectionCountsReturnsNilWhenFieldIsMissing() throws {
    let fullJSON = """
      {
        "type": "notify",
        "event_type": "connection.created",
        "channel_connections": 3,
        "channel_sendonly_connections": 1,
        "channel_recvonly_connections": 2,
        "channel_sendrecv_connections": 4
      }
      """
    for key in [
      "channel_connections", "channel_sendonly_connections",
      "channel_recvonly_connections", "channel_sendrecv_connections",
    ] {
      let signaling = try decodeNotify(try removeJSONField(key, from: fullJSON))
      guard case .notify(let notify) = signaling else {
        XCTFail("notify に復号できること")
        return
      }
      XCTAssertNil(
        MediaChannel.connectionCounts(from: notify),
        "\(key) が欠けている場合は nil になること")
    }
  }
}
