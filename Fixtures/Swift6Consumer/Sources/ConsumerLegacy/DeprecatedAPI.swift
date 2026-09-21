// 検査する契約:
//   - 非推奨 API を使っても deprecation warning に留まり、warnings-as-errors の
//     target でも build できること
// 期待する診断: deprecation warning のみ (error 0 件)
import Foundation
import Sora

/// 非推奨の ICEServerInfo を組み立てる。
func makeLegacyICEServerInfo() -> ICEServerInfo {
  let info = ICEServerInfo(
    urls: ["stun:stun.example.com"],
    userName: nil,
    credential: nil,
    tlsSecurityPolicy: .secure
  )
  info.tlsSecurityPolicy = .insecure
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
