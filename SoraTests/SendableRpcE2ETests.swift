import XCTest

@testable import Sora

/// Sendable な RPC API (`MediaChannel.sendableRPC`) の E2E テスト
///
/// 実 DataChannel と実 Sora の RPC を使い、組み込みメソッド (`RequestSimulcastRid`) と
/// 利用者定義の `SendableRPCMethodProtocol` 準拠型で新 API の挙動を検証する。
/// モックやスタブは使用しない。
///
/// 新 API は既存 `MediaChannel.rpc` と同じ送受信経路 (`performRPC` と `RPCChannel` の pending)
/// を使う。timeout / cancellation / disconnect と競合したときの終端は既存 `RpcE2ETests` /
/// `ConcurrencyStressE2ETests` が検証しているため、ここでは新 API 固有の差分
/// (戻り値が `SendableRPCResponse<M.Result>` になること、利用者定義型を呼べること、
/// notification が `nil` になること、server error が既存 `SoraError.rpcServerError(detail:)`
/// で返ること、キャンセル後に pending が残らないこと) に絞る。
final class SendableRpcE2ETests: E2ETestBase {
  /// 正常結果が `SendableRPCResponse` として返り、`@Sendable` closure を越えられること
  func testSendableRPCResultsOverDataChannel() throws {
    let channelId = buildChannelId(unique: true)
    let channel = try connectRPCChannel(channelId: channelId)

    // `MediaChannel` は Sendable ではないため、参照を保持するだけの box 経由で
    // `@Sendable` closure へ渡す (既存の `RpcE2ETests` と同じ方針)
    let box = SendableRPCChannelBox(channel)
    let successExpectation = self.expectation(description: "sendableRPC の正常結果が返ること")
    var observedResult: RequestSimulcastRidResult?
    box.callSimulcastRID(rid: .r0) { result in
      // SendableRPCResponse は Sendable のため、@Sendable closure の中でも値として扱える
      if case .success(let response) = result {
        observedResult = response?.result
      }
      successExpectation.fulfill()
    }
    wait(for: [successExpectation], timeout: 15)
    disconnectAndVerify(channel: channel)

    let result = try XCTUnwrap(observedResult, "sendableRPC が結果を返すこと")
    XCTAssertEqual(result.channelId, channelId, "結果のチャンネル ID が接続先と一致すること")
    XCTAssertFalse(result.receiverConnectionId.isEmpty, "受信者のコネクション ID が空でないこと")
    XCTAssertEqual(result.rid, .r0, "要求した rid が適用されること")
  }

  /// 利用者定義の `SendableRPCMethodProtocol` 準拠型で notification を送ると `nil` が返ること
  ///
  /// notification は result を待たないため、`Result` の decode 経路ではなく
  /// `isNotificationRequest` の分岐だけを検証する。あわせて、SDK の組み込み型ではない
  /// 利用者定義型でも `sendableRPC` を呼べることを確認する。
  func testSendableRPCNotificationReturnsNil() throws {
    let channelId = buildChannelId(unique: true)
    let channel = try connectRPCChannel(channelId: channelId)

    let box = SendableRPCChannelBox(channel)
    let notificationExpectation = self.expectation(
      description: "sendableRPC の notification が完了すること")
    var notificationReturnedNil = false
    box.callNotifyThenReturn { returnedNil in
      notificationReturnedNil = returnedNil
      notificationExpectation.fulfill()
    }
    wait(for: [notificationExpectation], timeout: 15)
    disconnectAndVerify(channel: channel)

    XCTAssertTrue(notificationReturnedNil, "isNotificationRequest が true の場合は nil が返ること")
  }

  /// server error が既存の `SoraError.rpcServerError(detail:)` で返ること
  ///
  /// `SendableRPCMethodProtocol` へ準拠した利用者定義型を使い、サーバーが受理しない params で
  /// 呼ぶ。サーバーがエラーを返さない環境では失敗させず、理由を残してスキップする。
  /// スキップが成功経路と notification の検証を巻き込まないよう、独立した test にしている。
  func testSendableRPCServerErrorReturnsDetail() throws {
    let channelId = buildChannelId(unique: true)
    let channel = try connectRPCChannel(channelId: channelId)

    let box = SendableRPCChannelBox(channel)
    let errorExpectation = self.expectation(description: "sendableRPC がサーバーエラーで終わること")
    var observedError: Error?
    box.callInvalidParams { result in
      if case .failure(let error) = result {
        observedError = error
      }
      errorExpectation.fulfill()
    }
    wait(for: [errorExpectation], timeout: 15)
    disconnectAndVerify(channel: channel)

    guard let observedError else {
      throw XCTSkip(
        "Sora サーバーが params の不要な項目を拒否せず成功応答を返したためスキップします")
    }
    guard let soraError = observedError as? SoraError,
      case .rpcServerError(let detail) = soraError
    else {
      XCTFail("rpcServerError を期待したが \(observedError) だった")
      return
    }
    XCTAssertNotEqual(detail.code, 0, "JSON-RPC 2.0 のエラーコードが 0 でないこと")
    XCTAssertFalse(detail.message.isEmpty, "エラーメッセージが空でないこと")
    // data は JSON-RPC 2.0 では任意フィールドのため、値の形は assert せず返ってきた値を残す
    print(
      "sendableRPC のサーバーエラー : エラーコード=\(detail.code) メッセージ=\(detail.message)"
        + " data=\(String(describing: detail.data))")
  }

  /// 実行中の `sendableRPC` の Task をキャンセルしても、すべての呼び出しが終端すること
  ///
  /// 新 API も `RPCChannel` の pending を `RPCChannel.cancel(identifier:)` で終端するため、
  /// キャンセル後に pending が残らない (すべての呼び出しが終端する) ことを検証する。
  /// 終端の理由 (`CancellationError` / timeout / 応答の到着) はサーバーの応答速度に依存して
  /// 変わり得るため要求しない (`ConcurrencyStressE2ETests` の cancellation scenario と同じ方針)。
  func testSendableRPCCancellationTerminatesAll() throws {
    let channelId = buildChannelId(unique: true)
    let channel = try connectRPCChannel(channelId: channelId)
    let box = SendableRPCChannelBox(channel)

    // 1. 実行中の sendableRPC をキャンセルする。終端しない場合は pending が残っている
    for attempt in 1...4 {
      let cancelledExpectation = self.expectation(
        description: "キャンセルした sendableRPC が終端すること (試行 \(attempt))")
      var cancelledExpectationFulfilled = false
      let task = Task {
        do {
          _ = try await box.sendableSimulcastRID(rid: .r0, timeout: 10)
        } catch {
          // 終端の理由は問わない。重要なのは終端すること
        }
        DispatchQueue.main.async {
          guard !cancelledExpectationFulfilled else { return }
          cancelledExpectationFulfilled = true
          cancelledExpectation.fulfill()
        }
      }
      // RPC が送信された後にキャンセルする
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        task.cancel()
      }
      let cancelledResult = XCTWaiter.wait(for: [cancelledExpectation], timeout: 15)
      if cancelledResult != .completed {
        XCTFail("sendableRPC が終端しない (試行 \(attempt)): pending が残存している可能性が高い")
        disconnectAndVerify(channel: channel)
        return
      }
    }

    // 2. timeout と cancellation を競合させる。すべての呼び出しが終端すること
    for attempt in 1...4 {
      let raceExpectation = self.expectation(
        description: "timeout と cancellation を競合させた sendableRPC が終端すること (試行 \(attempt))")
      var raceExpectationFulfilled = false
      let raceTask = Task {
        do {
          _ = try await box.sendableSimulcastRID(rid: .r1, timeout: 0.001)
        } catch {
          // timeout / cancellation のどちらで終わってもよい。重要なのは終端すること
        }
        DispatchQueue.main.async {
          guard !raceExpectationFulfilled else { return }
          raceExpectationFulfilled = true
          raceExpectation.fulfill()
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
        raceTask.cancel()
      }
      let raceResult = XCTWaiter.wait(for: [raceExpectation], timeout: 8)
      if raceResult != .completed {
        XCTFail("sendableRPC が終端しない (試行 \(attempt)): pending が残存している可能性が高い")
        disconnectAndVerify(channel: channel)
        return
      }
    }

    disconnectAndVerify(channel: channel)
  }

  /// RPC を利用できる recvonly 接続を確立し、rpc ラベルの DataChannel が OPEN するまで待つ
  ///
  /// `Configuration` の組み立て、access token のクレーム、`onDataChannelOpened` の設定、接続完了の
  /// 待機は `SendableRpcE2ETests` の各 test で共通のため、ここへ集約する。接続したチャンネルの
  /// 切断は呼び出し側が行う。
  ///
  /// rpc ラベルが払い出されない環境では RPC 自体を利用できないため、接続を切断してから
  /// `XCTSkip` を投げる。
  private func connectRPCChannel(channelId: String) throws -> MediaChannel {
    let connectExpectation = expectation(description: "recvonly の接続が完了すること")
    let rpcOpenedExpectation = expectation(description: "recvonly の rpc ラベルが OPEN すること")
    var rpcOpenedExpectationFulfilled = false

    // simulcast を有効にした recvonly を接続する。RPC の DataChannel を開くため
    // DataChannel signaling を有効にし、rpc_methods は access token のクレームで許可する
    var config = try buildConfiguration(role: .recvonly)
    config.channelId = channelId
    config.simulcastEnabled = true
    config.simulcastRequestRid = .r2
    config.dataChannelSignaling = true
    config.ignoreDisconnectWebSocket = true
    config.audioEnabled = false
    config.videoCodec = .vp8

    struct RPCTestMetadata: Encodable {
      // swift-format-ignore: AlwaysUseLowerCamelCase
      let access_token: String
    }
    let accessToken = try buildJWTAccessToken(
      channelId: channelId,
      privateClaims: [
        "rpc_methods": [RequestSimulcastRid.name],
        "simulcast": true,
        "simulcast_request_rid": "r2",
        "simulcast_rpc_rids": ["none", "r0", "r1", "r2"],
      ])
    config.signalingConnectMetadata = RPCTestMetadata(access_token: accessToken)

    config.mediaChannelHandlers.onDataChannelOpened = { _, label in
      DispatchQueue.main.async {
        guard label == "rpc", !rpcOpenedExpectationFulfilled else { return }
        rpcOpenedExpectationFulfilled = true
        rpcOpenedExpectation.fulfill()
      }
    }

    var channel: MediaChannel?
    _ = sora?.connect(configuration: config) { mediaChannel, error in
      DispatchQueue.main.async {
        if let error {
          XCTFail("recvonly の接続に失敗した : \(error)")
          connectExpectation.fulfill()
          return
        }
        guard let mediaChannel else {
          XCTFail("recvonly のメディアチャネルが nil")
          connectExpectation.fulfill()
          return
        }
        channel = mediaChannel
        connectExpectation.fulfill()
      }
    }

    wait(for: [connectExpectation], timeout: 35)
    guard let channel else {
      // 接続できなかった場合は rpc ラベルの expectation を消費して終了する
      _ = XCTWaiter.wait(for: [rpcOpenedExpectation], timeout: 0)
      throw XCTSkip("recvonly の接続に失敗したためスキップします")
    }

    // rpc ラベルの OPEN は接続完了より先に起きる場合がある。待つ前に `rpcChannel` の有無を
    // 先読みしないと、接続完了の時点で既に OPEN していた場合に expectation が fulfill されず、
    // test 全体が skip に化けて無検証で通る (既存 `RpcE2ETests` と同じ理由)
    if channel.peerChannel.rpcChannel != nil {
      rpcOpenedExpectationFulfilled = true
      rpcOpenedExpectation.fulfill()
    }
    let rpcOpenedResult = XCTWaiter.wait(for: [rpcOpenedExpectation], timeout: 10)
    guard rpcOpenedResult == .completed else {
      disconnectAndVerify(channel: channel)
      throw XCTSkip("Sora サーバーが rpc ラベルの DataChannel を払い出さないためスキップします")
    }

    return channel
  }
}

/// `RPCChannel.jsonData(fromFragment:)` の単体テスト
///
/// `RPCChannel.handleMessage` は `JSONSerialization.jsonObject` が返した `result` をこの関数で
/// `Data` へ直列化して pending へ渡す。`JSONSerialization.data(withJSONObject:)` は JSON として
/// 表現できない値を渡すと捕捉できない NSException でプロセスを終了させるため、事前検証の
/// 有無がそのまま abort の有無になる。object / array / scalar / null / 入れ子 / 非有限数の
/// それぞれで、直列化できる値だけが `Data` になり、できない値は捕捉可能な error になることを
/// 検証する (`SendableRpcE2ETests` の E2E は実サーバーが返す値しか通らないため、ここで
/// JSON の形を網羅する)。
final class RPCChannelJSONDataTests: XCTestCase {
  /// 断片の直列化結果が、元の JSON の値と一致すること
  private func assertSerialized(
    _ fragment: Any,
    equals expected: String,
    _ message: String
  ) throws {
    guard let json = String(data: try RPCChannel.jsonData(fromFragment: fragment), encoding: .utf8)
    else {
      XCTFail("直列化した Data を UTF-8 として読めない : \(message)")
      return
    }
    XCTAssertEqual(json, expected, message)
  }

  /// scalar の result が断片のまま直列化されること
  ///
  /// `isValidJSONObject` はトップレベルの断片に false を返すため、検証のために包む key
  /// (`jsonData(fromFragment:)` では `"value"`) が直列化結果へ現れる。decode 側はこの `Data` を
  /// `JSONDecoder` へそのまま渡すため、包んだ key は結果の解釈に影響しない
  /// (scalar を decode する場合は `JSONDecoder` の断片対応で `{"value":...}` の値が取り出される)。
  func testSerializesScalarFragment() throws {
    try assertSerialized(42, equals: #"{"value":42}"#, "Int の断片が直列化されること")
    try assertSerialized(
      "value", equals: #"{"value":"value"}"#, "String の断片が直列化されること")
    try assertSerialized(true, equals: #"{"value":true}"#, "Bool の断片が直列化されること")
  }

  /// `null` の result が `null` として直列化されること
  func testSerializesNullFragment() throws {
    try assertSerialized(
      NSNull(), equals: #"{"value":null}"#, "null の断片が直列化されること")
  }

  /// array の result が array のまま直列化されること
  ///
  /// array は `isValidJSONObject` を単独で通るため、包む key が付かない。
  func testSerializesArrayFragment() throws {
    try assertSerialized([1, 2, 3], equals: "[1,2,3]", "array の断片が直列化されること")
  }

  /// object の result が object のまま直列化されること
  func testSerializesObjectFragment() throws {
    try assertSerialized(
      ["key": "value"] as [String: Any],
      equals: #"{"key":"value"}"#,
      "object の断片が直列化されること")
  }

  /// 入れ子の object / array / null / scalar が再帰的に直列化されること
  func testSerializesNestedFragment() throws {
    try assertSerialized(
      ["key": ["nested": [1, NSNull(), "x"]]] as [String: Any],
      equals: #"{"key":{"nested":[1,null,"x"]}}"#,
      "入れ子の断片が直列化されること")
  }

  /// JSON の数値として表現できない値が、捕捉可能な error になること
  ///
  /// `{"result": -1e999}` を `JSONSerialization.jsonObject` が返すと `Double` の `-inf` に
  /// なる。事前検証が無い場合、`JSONSerialization.data(withJSONObject:)` が
  /// `NSInvalidArgumentException` を送出してプロセスが終了する (abort)。
  /// この test が失敗ではなく error を返すこと自体が、事前検証が効いていることの確認になる。
  func testRejectsNonFiniteNumberFragment() throws {
    let fragment: Any = -Double.infinity
    XCTAssertFalse(
      JSONSerialization.isValidJSONObject(["v": fragment]),
      "非有限数が JSON の値として無効であること (前提の確認)")
    XCTAssertThrowsError(
      try RPCChannel.jsonData(fromFragment: fragment),
      "非有限数の断片は error になること"
    ) { error in
      guard case EncodingError.invalidValue = error else {
        XCTFail("EncodingError.invalidValue を期待したが \(error) だった")
        return
      }
    }
  }

  /// JSON の値ではない object が、捕捉可能な error になること
  ///
  /// `isValidJSONObject` が false を返す値の代表として `Date` を使う (JSON の数値や文字列では
  /// なく、`JSONSerialization` が受理しない)。
  func testRejectsNonJSONFragment() throws {
    XCTAssertThrowsError(
      try RPCChannel.jsonData(fromFragment: ["date": Date()] as [String: Any]),
      "JSON の値ではない object は error になること"
    ) { error in
      guard case EncodingError.invalidValue = error else {
        XCTFail("EncodingError.invalidValue を期待したが \(error) だった")
        return
      }
    }
  }
}

/// `sendableRPC` の結果を main actor 上で受け取る completion。
///
/// completion を `@MainActor @Sendable` にすることで、テストの local 変数を data race なく
/// 更新できる (`SendableRPCResponse` は Sendable のため closure の境界を越えられる)。
private typealias SendableRPCCompletion =
  @MainActor @Sendable (
    Result<SendableRPCResponse<RequestSimulcastRidResult>?, Error>
  ) -> Void

/// `MediaChannel` の `sendableRPC` を `Task` の `@Sendable` closure へ渡すための box
///
/// `MediaChannel` は Sendable ではないため、参照をこの box へまとめて `@Sendable` closure から
/// 触れるようにする。可変状態を持たず、参照を保持するだけである。安全性は `MediaChannel` の
/// 内部同期に依存する (`RpcE2ETests` の `RPCChannelBox` と同じ方針)。
private final class SendableRPCChannelBox: @unchecked Sendable {
  private let channel: MediaChannel

  init(_ channel: MediaChannel) {
    self.channel = channel
  }

  /// 組み込みの Sendable な RPC メソッド (`RequestSimulcastRid`) を呼ぶ
  ///
  /// 結果は main queue へ配送して completion へ渡す。
  func callSimulcastRID(
    rid: Rid,
    timeout: TimeInterval = 5.0,
    completion: @escaping SendableRPCCompletion
  ) {
    Task { @MainActor in
      do {
        let response = try await channel.sendableRPC(
          method: RequestSimulcastRid.self,
          params: RequestSimulcastRidParams(rid: rid),
          timeout: timeout)
        completion(.success(response))
      } catch {
        completion(.failure(error))
      }
    }
  }

  /// 利用者定義の `SendableRPCMethodProtocol` 準拠型で notification を送る
  ///
  /// notification は `nil` が返ることを確認するため、`nil` かどうかを completion へ渡す。
  func callNotifyThenReturn(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
    Task { @MainActor in
      do {
        let response = try await channel.sendableRPC(
          method: SendableRPCNotifyMethod.self,
          params: SendableRPCNotifyMethodParams(),
          isNotificationRequest: true)
        completion(response == nil)
      } catch {
        completion(false)
      }
    }
  }

  /// 利用者定義の `SendableRPCMethodProtocol` 準拠型で、サーバーが受理しない params を送る
  ///
  /// result の型は呼び出し側で使わないため、成否だけを completion へ渡す
  /// (`SendableRPCResponse<M.Result>` は `M.Result` に依存するため型を固定できない)。
  func callInvalidParams(completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) {
    Task { @MainActor in
      do {
        _ = try await channel.sendableRPC(
          method: SendableInvalidParamsRPCMethod.self,
          params: SendableInvalidParamsRPCMethodParams(rid: "r0", unexpected: "unsupported"))
        completion(.success(()))
      } catch {
        completion(.failure(error))
      }
    }
  }

  /// `RequestSimulcastRid` を timeout と cancellation の競合検証で使うために直接 await する
  func sendableSimulcastRID(rid: Rid, timeout: TimeInterval) async throws
    -> SendableRPCResponse<RequestSimulcastRidResult>?
  {
    try await channel.sendableRPC(
      method: RequestSimulcastRid.self,
      params: RequestSimulcastRidParams(rid: rid),
      timeout: timeout)
  }
}

/// 利用者定義の `SendableRPCMethodProtocol` 準拠型
///
/// SDK が提供する型ではなく、利用者側で新 protocol へ準拠した型を定義できることを確認する。
/// メソッド名は `RequestSimulcastRid` と同じにして、実サーバーが処理できるようにする。
private enum SendableRPCNotifyMethod: SendableRPCMethodProtocol {
  typealias Params = SendableRPCNotifyMethodParams
  typealias Result = SendableRPCNotifyMethodResult

  static var name: String { RequestSimulcastRid.name }
}

/// `SendableRPCNotifyMethod` のパラメータ。
///
/// メソッド名が `RequestSimulcastRid` のため、サーバーはこの params を
/// `RequestSimulcastRidParams` として解釈する。項目を持たせるとサーバーが未知の項目として
/// 拒否し得るうえ、notification では params の値を使わないため、項目を持たない。
private struct SendableRPCNotifyMethodParams: Encodable, Sendable {}

/// `SendableRPCNotifyMethod` の戻り値。
private struct SendableRPCNotifyMethodResult: Decodable, Sendable {
  let channelId: String
}

/// `params` にサーバーが受理しない項目を含めて RPC を呼ぶための `SendableRPCMethodProtocol` 準拠型
///
/// Sora の RPC は `params` に不要な項目が含まれている場合にエラー応答を返すため、
/// 新 API の server error 経路を実サーバーで確認するために使う。
private enum SendableInvalidParamsRPCMethod: SendableRPCMethodProtocol {
  typealias Params = SendableInvalidParamsRPCMethodParams
  typealias Result = SendableInvalidParamsRPCMethodResult

  static var name: String { RequestSimulcastRid.name }
}

/// `SendableInvalidParamsRPCMethod` のパラメータ。
private struct SendableInvalidParamsRPCMethodParams: Encodable, Sendable {
  let rid: String
  let unexpected: String
}

/// `SendableInvalidParamsRPCMethod` の戻り値。
private struct SendableInvalidParamsRPCMethodResult: Decodable, Sendable {
  let rid: String

}
