// EXPECT-DIAGNOSTIC: SendableClosureCaptures
// 検査する契約: 既存 RPCMethodProtocol の Params / Result は Sendable を要求しないため、
// @Sendable closure へキャプチャすると compile できないこと。
// (Sendable な RPC API は SendableRPCMethodProtocol と MediaChannel.sendableRPC が提供する)
// この file はどの target にも含めない。
import Sora

enum LegacyAttachRPCMethod: RPCMethodProtocol {
  typealias Params = LegacyAttachReference
  typealias Result = LegacyAttachReference

  static var name: String { "jp.shiguredo.swift6-consumer/LegacyAttach" }
}

/// 非 Sendable な associated type。
///
/// class は `Sendable` が推論されないため、非 Sendable な params / result の代わりに使う。
/// (internal な struct は `Sendable` が推論されるため、この検証には使えない)
final class LegacyAttachReference: Codable {
  var message: String = ""

  init() {}

  init(from decoder: Decoder) throws {
    _ = try decoder.container(keyedBy: CodingKeys.self)
  }

  func encode(to encoder: Encoder) throws {
    _ = encoder.container(keyedBy: CodingKeys.self)
  }

  private enum CodingKeys: String, CodingKey {
    case message
  }
}

/// 既存 RPCMethodProtocol の associated type を @Sendable closure へキャプチャする。
func captureLegacyRPCParams(_ params: LegacyAttachRPCMethod.Params) {
  let closure: @Sendable () -> Void = {
    _ = params
  }
  _ = closure
}

/// 既存 RPCMethodProtocol の result を @Sendable closure へキャプチャする。
func captureLegacyRPCResult(_ result: LegacyAttachRPCMethod.Result) {
  let closure: @Sendable () -> Void = {
    _ = result
  }
  _ = closure
}
