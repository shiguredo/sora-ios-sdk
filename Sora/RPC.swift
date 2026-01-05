import Foundation

/// RPC の ID を表す型。
public enum RPCID: Hashable {
  case int(Int)
  case string(String)

  init?(any value: Any) {
    if let intValue = value as? Int {
      self = .int(intValue)
      return
    }
    // JSONSerialization は整数を NSNumber として返すことがあるためこちらも考慮する
    if let numberValue = value as? NSNumber {
      self = .int(numberValue.intValue)
      return
    }
    if let stringValue = value as? String {
      self = .string(stringValue)
      return
    }
    return nil
  }

  var jsonValue: Any {
    switch self {
    case .int(let value):
      return value
    case .string(let value):
      return value
    }
  }
}

/// RPC エラー応答の詳細。
public struct RPCErrorDetail {
  public let code: Int
  public let message: String
  public let data: Any?
}

/// RPC 成功応答。
public struct RPCResponse<Result> {
  public let jsonrpc: String
  public let id: RPCID
  public let result: Result

  public init(id: RPCID, result: Result) {
    self.jsonrpc = "2.0"
    self.id = id
    self.result = result
  }
}

/// DataChannel 経由の RPC を扱うクラス。
public final class RPCChannel {
  /// pending 管理用の構造体
  private struct Pending {
    let completion: (Result<RPCResponse<Any>?, SoraError>) -> Void
    let timeoutWorkItem: DispatchWorkItem
  }

  private let dataChannel: DataChannel
  private let queue = DispatchQueue(
    label: "jp.shiguredo.sora-ios-sdk.rpc.channel", attributes: .concurrent)
  private var nextId: Int = 1
  private var pendings: [RPCID: Pending] = [:]

  /// Sora から払い出されたメソッド一覧 (メソッド名の文字列リスト)
  /// MediaChannel.rpcMethods で RPCMethod Enum に変換されます
  let allowedMethods: [String]
  private let allowedMethodNames: Set<String>

  /// Sora から払い出されたサイマルキャスト rid の一覧
  let simulcastRpcRids: [SimulcastRequestRid]

  init?(
    dataChannel: DataChannel, rpcMethods: [String], simulcastRpcRids: [SimulcastRequestRid]
  ) {
    guard !rpcMethods.isEmpty else {
      return nil
    }
    self.dataChannel = dataChannel
    self.allowedMethods = rpcMethods
    self.allowedMethodNames = Set(rpcMethods)
    self.simulcastRpcRids = simulcastRpcRids
  }

  /// RPC が利用可能かを返す。
  var isAvailable: Bool {
    dataChannel.readyState == .open
  }

  /// RPC を送信する。
  @discardableResult
  func call(
    methodName: String,
    params: Encodable? = nil,
    isNotificationRequest: Bool = false,
    timeout: TimeInterval = 5.0,
    completion: ((Result<RPCResponse<Any>?, SoraError>) -> Void)? = nil
  ) -> Bool {
    guard isAvailable else {
      completion?(.failure(SoraError.rpcUnavailable(reason: "DataChannel is not open")))
      return false
    }

    guard allowedMethodNames.contains(methodName) else {
      completion?(.failure(SoraError.rpcMethodNotAllowed(method: methodName)))
      return false
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
        return false
      }
    }

    var identifier: RPCID?
    if !isNotificationRequest {
      let nextIdentifier = nextIdentifier()
      identifier = nextIdentifier
      payload["id"] = nextIdentifier.jsonValue
    }

    guard JSONSerialization.isValidJSONObject(payload) else {
      completion?(.failure(SoraError.rpcEncodingError(reason: "invalid JSON payload")))
      return false
    }

    let data: Data
    do {
      data = try JSONSerialization.data(withJSONObject: payload, options: [])
    } catch {
      completion?(.failure(SoraError.rpcEncodingError(reason: error.localizedDescription)))
      return false
    }

    var pending: Pending?
    if !isNotificationRequest, let identifier {
      // タイムアウト時に実行されるタスク
      let workItem = DispatchWorkItem { [weak self] in
        self?.finishPending(id: identifier, result: .failure(SoraError.rpcTimeout))
      }
      let createdPending = Pending(
        completion: { result in completion?(result) },
        timeoutWorkItem: workItem)
      pending = createdPending
      queue.sync(flags: .barrier) {
        self.pendings[identifier] = createdPending
      }
    }

    Logger.debug(type: .dataChannel, message: "send rpc: \(payload)")
    let sent = dataChannel.send(data)
    if !sent {
      if let identifier {
        finishPending(
          id: identifier,
          result: .failure(SoraError.rpcDataChannelClosed(reason: "failed to send rpc message")))
      } else {
        completion?(.failure(SoraError.rpcDataChannelClosed(reason: "failed to send rpc message")))
      }
      return false
    }

    if !isNotificationRequest, let pending {
      // リクエストのタイムアウトをスケジュール
      DispatchQueue.global().asyncAfter(
        deadline: .now() + timeout, execute: pending.timeoutWorkItem)
    } else {
      // notification の場合は即座に完了
      completion?(.success(nil))
    }

    return true
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

    guard let idValue = json["id"], let identifier = RPCID(any: idValue) else {
      Logger.error(type: .dataChannel, message: "rpc response id is missing")
      return
    }

    if let result = json["result"] {
      let response = RPCResponse<Any>(id: identifier, result: result)
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

  /// すべての pending を失敗扱いで終了する。
  func invalidate(reason: SoraError) {
    let snapshots: [RPCID: Pending] = queue.sync(flags: .barrier) {
      let current = pendings
      pendings.removeAll()
      return current
    }
    for (_, pending) in snapshots {
      pending.timeoutWorkItem.cancel()
      pending.completion(.failure(reason))
    }
  }

  private func nextIdentifier() -> RPCID {
    queue.sync(flags: .barrier) {
      defer { nextId += 1 }
      return RPCID.int(nextId)
    }
  }

  private func encodeParams(_ params: Encodable) throws -> Any {
    let encoder = JSONEncoder()
    let data = try encoder.encode(EncodableBox(params))
    let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    return object
  }

  private func finishPending(id: RPCID, result: Result<RPCResponse<Any>?, SoraError>) {
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
