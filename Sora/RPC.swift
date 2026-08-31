import Foundation

/// RPC エラー応答の詳細。
public struct RPCErrorDetail {
  /// JSON-RPC 2.0 のエラーコード。
  public let code: Int
  /// エラーメッセージ。
  public let message: String
  /// エラーに関する追加情報。
  public let data: Any?
}

/// RPC 成功応答。
public struct RPCResponse<Result> {
  /// JSON-RPC プロトコルのバージョン。
  public let jsonrpc: String
  /// リクエストと対応する ID。
  public let id: Int
  /// リクエストが正常終了した場合の結果情報。
  public let result: Result

  /// RPC 成功応答を作成する。
  /// - Parameters:
  ///   - id: リクエストと対応する ID。
  ///   - result: RPC 呼び出しの結果。
  public init(id: Int, result: Result) {
    self.jsonrpc = "2.0"
    self.id = id
    self.result = result
  }
}

// `result` は JSONSerialization が返す読み取り専用の値として扱う前提で
// actor 境界を越えるために `@unchecked Sendable` を付与します。
struct RPCRawResponse: @unchecked Sendable {
  let jsonrpc: String
  let id: Int
  let result: Any
}

/// DataChannel 経由の RPC を扱うクラス。
///
/// `@unchecked Sendable` を付与しているのは、`RPCChannel` の可変状態
/// (`pendings` / `nextId` / `isInvalidated`) は concurrent dispatch queue の
/// barrier 配下でのみアクセスされ、`RPCChannel` 外部からは参照されないため。
/// Swift コンパイラは concurrent dispatch queue の保護を認識できないため、
/// ベースクラスは `@unchecked Sendable` と宣言し、更新は必ず barrier 配下で行う。
final class RPCChannel: @unchecked Sendable {
  /// pending 管理用の構造体
  private struct Pending {
    let completion: (Result<RPCRawResponse?, Error>) -> Void
    let timeoutWorkItem: DispatchWorkItem
  }

  private let dataChannel: DataChannel
  private let queue = DispatchQueue(
    label: "jp.shiguredo.sora-ios-sdk.rpc.channel", attributes: .concurrent)
  private var nextId: Int = 1
  private var pendings: [Int: Pending] = [:]
  /// invalidate() が呼ばれたかどうか。invalidate 後の call() を拒否するために保持する。
  /// アクセスは queue の barrier 配下で行う
  private var isInvalidated = false

  init(dataChannel: DataChannel) {
    self.dataChannel = dataChannel
  }

  /// RPC が利用可能かを返す。
  var isAvailable: Bool {
    dataChannel.readyState == .open
  }

  /// RPC を送信する。
  ///
  /// - Returns: リクエストとして登録された RPC ID (notification は nil)。
  ///   登録されなかった場合は nil を返し、completion に失敗結果を渡す
  @discardableResult
  func call(
    methodName: String,
    params: Encodable? = nil,
    isNotificationRequest: Bool = false,
    timeout: TimeInterval = 5.0,
    completion: ((Result<RPCRawResponse?, Error>) -> Void)? = nil
  ) -> Int? {
    guard isAvailable else {
      completion?(.failure(SoraError.rpcUnavailable(reason: "DataChannel is not open")))
      return nil
    }

    var payload: [String: Any] = [
      "jsonrpc": "2.0",
      "method": methodName,
    ]

    if let params {
      do {
        payload["params"] = try encodeParams(params)
      } catch {
        completion?(.failure(SoraError.rpcEncodingError(reason: error.localizedDescription)))
        return nil
      }
    }

    var identifier: Int?
    if !isNotificationRequest {
      let nextIdentifier = nextIdentifier()
      identifier = nextIdentifier
      payload["id"] = nextIdentifier
    }

    guard JSONSerialization.isValidJSONObject(payload) else {
      completion?(.failure(SoraError.rpcEncodingError(reason: "invalid JSON payload")))
      return nil
    }

    let data: Data
    do {
      data = try JSONSerialization.data(withJSONObject: payload, options: [])
    } catch {
      completion?(.failure(SoraError.rpcEncodingError(reason: error.localizedDescription)))
      return nil
    }

    // 利用可能性の確認と pending の登録を 1 つの barrier で行い、
    // その間に呼び出し側の invalidate() が割り込まないようにする。
    // invalidate が終わった後に登録された pending は、timeout work item 経由で
    // 必ず完了されるが、RPCChannel が解放済みの場合は weakly captured された
    // work item が実行されないため、登録自体を拒否する
    if let identifier {
      let createdPending = makePending(identifier: identifier, completion: completion)
      let registered = queue.sync(flags: .barrier) { () -> Pending? in
        if isInvalidated {
          return nil
        }
        pendings[identifier] = createdPending
        return createdPending
      }
      guard let registered else {
        completion?(
          .failure(SoraError.rpcDataChannelClosed(reason: "RPC channel is invalidated")))
        return nil
      }
      let sent = dataChannel.send(data)
      if !sent {
        finishPending(
          id: identifier,
          result: .failure(SoraError.rpcDataChannelClosed(reason: "failed to send rpc message")))
        return nil
      }
      // リクエストのタイムアウトをスケジュール
      DispatchQueue.global().asyncAfter(
        deadline: .now() + timeout, execute: registered.timeoutWorkItem)
      return identifier
    }

    // notification は id を持たず pending も作らない。登録の有無の代わりに
    // invalidate 後の送信を拒否する
    let stillValid = queue.sync(flags: .barrier) { () -> Bool in
      !isInvalidated
    }
    guard stillValid else {
      completion?(
        .failure(SoraError.rpcDataChannelClosed(reason: "RPC channel is invalidated")))
      return nil
    }

    Logger.debug(type: .dataChannel, message: "send rpc: \(payload)")
    let sent = dataChannel.send(data)
    if !sent {
      completion?(.failure(SoraError.rpcDataChannelClosed(reason: "failed to send rpc message")))
      return nil
    }

    // notification の場合は即座に完了
    completion?(.success(nil))
    return nil
  }

  /// timeout 用の pending を作成して返す
  private func makePending(
    identifier: Int,
    completion: ((Result<RPCRawResponse?, Error>) -> Void)?
  ) -> Pending {
    let workItem = DispatchWorkItem { [weak self] in
      // RPCChannel が解放済みの場合、invalidate が全 pending を終端済みである
      // (invalidate 後に登録されないことを barrier で保証しているため)
      self?.finishPending(id: identifier, result: .failure(SoraError.rpcTimeout))
    }
    return Pending(
      completion: { result in completion?(result) },
      timeoutWorkItem: workItem)
  }

  /// DataChannel で受信したメッセージを処理する。
  func handleMessage(_ data: Data) {
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data, options: [])
    } catch {
      Logger.error(
        type: .dataChannel, message: "rpc message decode failed: \(error.localizedDescription)")
      return
    }

    guard let json = object as? [String: Any] else {
      Logger.error(type: .dataChannel, message: "rpc message is not dictionary")
      return
    }

    guard let version = json["jsonrpc"] as? String, version == "2.0" else {
      Logger.error(type: .dataChannel, message: "rpc message is not json-rpc 2.0")
      return
    }

    if let method = json["method"] as? String {
      // SDK から request / notification を送り、response を Sora から受け取る
      // 一方通行の通信が前提になっており、 request / notification が届いても
      // 処理できないためエラーにする
      Logger.error(
        type: .dataChannel, message: "rpc request/notification is not supported: \(method)")
      return
    }

    guard let idValue = json["id"] else {
      Logger.error(type: .dataChannel, message: "rpc response id is missing")
      return
    }
    let identifier: Int
    do {
      identifier = try Self.parseResponseID(idValue)
    } catch {
      Logger.error(
        type: .dataChannel,
        message: "rpc response id is invalid: \(error.localizedDescription)")
      return
    }

    if let result = json["result"] {
      let response = RPCRawResponse(jsonrpc: version, id: identifier, result: result)
      finishPending(id: identifier, result: .success(response))
      return
    }

    if let error = json["error"] as? [String: Any],
      let code = error["code"] as? Int,
      let message = error["message"] as? String
    {
      let detail = RPCErrorDetail(code: code, message: message, data: error["data"])
      finishPending(id: identifier, result: .failure(SoraError.rpcServerError(detail: detail)))
      return
    }

    Logger.warn(type: .dataChannel, message: "rpc response is unknown format")
  }

  /// RPC チャンネルを無効化し、すべての pending を失敗扱いで終了する。
  ///
  /// 呼び出し後は isInvalidated になり、以降の call() は pending を登録せず失敗する。
  /// 利用者からは、RPC の DataChannel が切断されたことを示す理由が渡される。
  func invalidate(reason: SoraError) {
    let snapshots: [Int: Pending] = queue.sync(flags: .barrier) {
      if isInvalidated {
        return [:]
      }
      // invalidate 後の pending 登録を拒否する
      isInvalidated = true
      let current = pendings
      pendings.removeAll()
      return current
    }
    for (_, pending) in snapshots {
      pending.timeoutWorkItem.cancel()
      pending.completion(.failure(reason))
    }
  }

  /// 指定された pending をキャンセルし、CancellationError で終端する。
  ///
  /// タスクキャンセルによりレスポンスを待たなくなった場合に呼ぶ。
  func cancel(identifier: Int) {
    finishPending(id: identifier, result: .failure(CancellationError()))
  }

  private func nextIdentifier() -> Int {
    queue.sync(flags: .barrier) {
      defer { nextId += 1 }
      return nextId
    }
  }

  private func encodeParams(_ params: Encodable) throws -> Any {
    let encoder = JSONEncoder()
    let data = try encoder.encode(EncodableBox(params))
    let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    return object
  }

  private func finishPending(id: Int, result: Result<RPCRawResponse?, Error>) {
    let pending = queue.sync(flags: .barrier) { () -> Pending? in
      let value = pendings[id]
      pendings.removeValue(forKey: id)
      return value
    }

    guard let pending else {
      Logger.warn(type: .dataChannel, message: "rpc pending not found for id: \(id)")
      return
    }
    pending.timeoutWorkItem.cancel()
    pending.completion(result)
  }

  private static func parseResponseID(_ value: Any) throws -> Int {
    if let intValue = value as? Int {
      return intValue
    }
    if let numberValue = value as? NSNumber {
      return numberValue.intValue
    } else {
      throw SoraError.rpcDecodingError(
        reason: "response id must be Int or NSNumber: \(type(of: value))")
    }
  }
}

/// Encodable を JSONSerialization で扱える形にするラッパー。
///
/// JSONSerialization は top-level に JSON オブジェクト（辞書またはペア）を要求するため、
/// スカラー値（Int, String, Bool など）を直接エンコードすることができない。
/// そのため、EncodableBox でラップする
private struct EncodableBox: Encodable {
  let encodeClosure: (Encoder) throws -> Void

  init<T: Encodable>(_ value: T) {
    encodeClosure = { encoder in
      try value.encode(to: encoder)
    }
  }

  func encode(to encoder: Encoder) throws {
    try encodeClosure(encoder)
  }
}

/// `MediaChannel.rpc()` 内でタスクキャンセル通知に使う RPC ID をスレッドセーフに保持するストア。
///
/// `withTaskCancellationHandler` の `onCancel` は別スレッドから実行されるため、
/// `NSLock` で保護した単一の `Int?` を共有する。ID は 1 回の `rpc()` 呼び出しに
/// つき 1 つだけ登録され、読み取りは 1 回だけ行われる。
///
/// `@unchecked Sendable` を付与しているのは、可変状態が `value` (単一の `Int?`) のみで、
/// その読み書きはすべて `stateLock` 配下で行われるため。Swift コンパイラは
/// `NSLock` による保護を認識できないため、手動で安全を宣言する。
final class CancelledRPCIDStore: @unchecked Sendable {
  private let stateLock = NSLock()
  private var value: Int?

  init() {}

  func set(_ value: Int) {
    stateLock.lock()
    defer { stateLock.unlock() }
    self.value = value
  }

  func get() -> Int? {
    stateLock.lock()
    defer { stateLock.unlock() }
    return value
  }
}
