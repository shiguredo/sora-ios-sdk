// 検査する契約:
//   - 非推奨 API を使っても deprecation warning に留まり、warnings-as-errors の
//     target でも build できること
// 期待する診断: deprecation warning のみ (error 0 件)
import Foundation
import Sora

/// 非推奨の tlsSecurityPolicy 引数と property を持つ ICEServerInfo を組み立てる。
func makeLegacyICEServerInfo() -> ICEServerInfo {
  let info = ICEServerInfo(
    urls: ["stun:stun.example.com"],
    userName: nil,
    credential: nil,
    tlsSecurityPolicy: .secure
  )
  info.tlsSecurityPolicy = .insecure
  // CI の deprecation 検査が TLSSecurityPolicy と secure の symbol 名を要求するため、
  // property 経由ではなく enum と case を明示的に参照する
  _ = TLSSecurityPolicy.secure
  return info
}

/// 非推奨の接続設定のプロパティを使う。
func makeLegacyConfiguration(url: URL, channelId: String) -> Configuration {
  var configuration = Configuration(
    url: url,
    channelId: channelId,
    role: .sendrecv,
    multistreamEnabled: false
  )
  configuration.simulcastRid = .r1
  configuration.spotlightEnabled = .disabled
  // init の引数ラベルは非推奨ではないため、property として参照して warning を確認する
  _ = configuration.multistreamEnabled
  return configuration
}

/// 非推奨の MediaChannelHandlers を使う。
func makeLegacyMediaChannelHandlers() -> MediaChannelHandlers {
  let handlers = MediaChannelHandlers()
  handlers.onDisconnectLegacy = { error in
    _ = error
  }
  handlers.onReceiveSignaling = { signaling in
    _ = signaling
  }
  return handlers
}
