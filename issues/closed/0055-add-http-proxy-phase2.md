# HTTP Proxy 対応 Phase 2（OS 設定の自動参照）

- Priority: Low
- Created: 2026-06-06
- Completed: 2026-09-23
- Model: Sonnet 4.6
- Branch: feature/add-http-proxy-phase2
- Polished: 2026-06-06

## 目的

`Configuration.proxy` が未設定（`nil`）の場合に OS のシステムプロキシ設定を自動参照し、手動設定なしでプロキシ経由の接続を可能にする。企業ネットワーク環境での設定コストを削減する。

## 優先度根拠

Phase 1 で手動プロキシ設定（`Configuration.proxy`）が既に利用可能なため、Phase 2 は必須ではなく利便性向上のみ。MDM / VPN プロファイルが設定するプロキシを `CFNetworkCopySystemProxySettings()` で確実に取得できるかどうかの検証も必要であり、Low とする。

PAC ファイル対応は本 issue のスコープ外とし、別途 issue で検討する。

## 現状

Phase 1 の実装（`CHANGES.md` の `## 2022.5.0` セクション `[ADD] HTTP プロキシに対応する` で実装済み）では、`Configuration.proxy` が `nil` の場合に OS のシステムプロキシ設定は参照されない。

- **WebSocket 側**（`URLSessionWebSocketChannel.swift:33-60`）: `URLSessionConfiguration.ephemeral` を使用し、`proxy` が `nil` の場合は `connectionProxyDictionary` を設定しないため OS プロキシは無視される（`ephemeral` はデフォルトでシステムプロキシを参照しない）
- **TURN 側**（`NativePeerChannelFactory.swift:77-107`）: `proxy` が `nil` の場合は 91 行目の `else` ブランチで、`certificateVerifier` の有無に応じた proxy なしの overload が呼ばれる

## 設計方針

### WebSocket 側の変更（`URLSessionWebSocketChannel.swift`）

`URLSessionWebSocketChannel.connect(delegateQueue:)`（`URLSessionWebSocketChannel.swift:30`）内の `if let proxy {` ブロック（33-60 行目）の直後（61 行目の位置）に、`proxy` が `nil` かつ OS プロキシ設定が存在する場合の分岐を追加する:

```swift
// proxy が nil の場合は OS のシステムプロキシ設定を参照する
if proxy == nil,
   let systemSettings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [AnyHashable: Any] {
    configuration.connectionProxyDictionary = systemSettings
}
```

`CFNetworkCopySystemProxySettings()` の戻り値は `Unmanaged<CFDictionary>?` であり、`.takeRetainedValue()` で `CFDictionary` を取り出し、`[AnyHashable: Any]` にキャストして `connectionProxyDictionary` に設定する（`connectionProxyDictionary` の型は `[AnyHashable: Any]?`）。

### TURN 側の調査事項（`NativePeerChannelFactory.swift`）

libwebrtc の `RTCProxyType` は `none / socks5 / https` の 3 種のみ。`CFNetworkCopySystemProxySettings()` の返値を `RTCProxyType.https` として渡せるかを確認する。また libwebrtc の `ProxyInfo` に `autodetect` フィールドが存在するが、iOS 上で OS プロキシを自動参照できるかは未検証であり、実装前に調査が必要。

### `proxy` 設定の優先順位

`Configuration.proxy` が非 `nil` の場合は手動設定を優先する。`nil` の場合にのみ OS プロキシ設定を参照する（フォールバック動作）。

## 完了条件

- `Configuration.proxy` が `nil` の状態で、iOS デバイスの Wi-Fi 設定アプリでのプロキシ設定（手動プロキシ）を行った後に SDK が WebSocket 接続を確立できること
- `Configuration.proxy` が非 `nil` の状態では `Configuration.proxy` による明示設定が優先され、Phase 1 の挙動が変わらないこと
- TURN 側への OS プロキシ参照の適用可否を調査し、適用可能であれば別 issue を起票すること、適用不可であれば調査結果を本 issue に追記すること
- `CHANGES.md` の `## develop` セクションにある既存の `[ADD]` エントリ（現在 4 件）の最後に以下を追記すること

```
- [ADD] Configuration.proxy が nil の場合に OS のシステムプロキシ設定を自動参照するようにする
  - @voluntas
```

## 解決方法

本 issue は closed とした。主要な変更対象（WebSocket 側の OS システムプロキシ自動参照）は現行実装で既に実現されていることを Apple 公式ドキュメントとの照合で確認し、かつ TURN 側は本 issue 自身の完了条件が別 issue を想定している（分割済み）ため、これ以上対応すべき作業が残っていないと判断した。

- WebSocket 側の「OS プロキシは無視される」前提は Apple 公式ドキュメントと矛盾する
  - `URLSession` クラスの概要は「transparent support for proxy servers and SOCKS gateways, as configured in the user's system preferences」（https://developer.apple.com/documentation/foundation/urlsession）
  - `URLSessionConfiguration.connectionProxyDictionary` は「The default value is NULL, which means that tasks use the default system settings」（https://developer.apple.com/documentation/foundation/urlsessionconfiguration/connectionproxydictionary）
  - `URLSessionConfiguration.ephemeral` は「similar to default sessions」であり、プロキシ設定に関する差異の記述はない
  - 現行実装の `URLSessionWebSocketChannel.connect(delegateQueue:)` は `Configuration.proxy` が nil の場合に `connectionProxyDictionary` を設定しない（= システム設定を使用）
  - したがって完了条件 1（Wi-Fi 設定の手動プロキシで WebSocket 接続が確立できること）は実装を待たずに満たされている状態であり、設計方針の追加コードは不要
- ソース位置の行番号はすべて現行コードと一致しない（作成時点からのずれ）ため、挿入位置の指示は実装者を誤らせる
  - `URLSessionWebSocketChannel.swift:33-60` とあるが、現行の `if let proxy {` ブロックは `connect(delegateQueue:)` 内の 41〜68 行目。指示の「61 行目の位置」はブロック内であり、挿入しても `proxy` が nil にならない不要な分岐になる
  - `NativePeerChannelFactory.swift:77-107` とあるが、現行の `createNativePeerChannel(webRTCConfiguration:proxy:caCertificates:delegate:)` は 186〜225 行目であり、「91 行目の else ブランチ」は現行の 209 行目
  - shiguredo-issues 規約でもソース位置は行番号でなくシンボル名で示すこととされている
- CHANGES.md の「既存の `[ADD]` エントリ（現在 4 件）」は誤り
  - `CHANGES.md` の `## develop` セクションには現在 `[ADD]` エントリがなく、`[UPDATE]` / `[FIX]` のみである
  - Phase 1 の `[ADD] HTTP プロキシに対応する` は `## 2022.5.0` に存在する（この記述だけは正しい）
- TURN 側の調査事項の細部は libwebrtc の実装と一致しない
  - `RTCProxyType` は `RTCProxyTypeNone / RTCProxyTypeHttps / RTCProxyTypeSocks5 / RTCProxyTypeUnknown` の 4 種である（shiguredo-webrtc-build/webrtc-build の `patches/ios_proxy.patch` で確認）
  - `ProxyInfo` は `webrtc::revive::ProxyInfo`（`autodetect` / `autoconfig_url` / `bypass_list` を持つ）だが、iOS の ObjC API は `proxyType / proxyAgent / proxyHostname / proxyPort / proxyUsername / proxyPassword` しか公開しておらず、`CFNetworkCopySystemProxySettings()` の結果をそのまま渡すことはできない。TURN 側の自動参照には webrtc-build 側のパッチ拡張の調査・適用が必要になる
- TURN 側の対応は本 issue の完了条件 3 が「適用可能であれば別 issue を起票する」としており、元々本 issue で実装する対象ではない（分割済み）。libwebrtc は URLSession と異なりシステムプロキシを自動参照しないため、この別 issue 候補自体は残るが、優先度・時期と webrtc-build 側パッチ拡張の可否判断が必要なため、本 polish では起票しない

以上のことから、本 issue として実装すべき変更は存在せず、closed とした。`Polished:` は更新しない（closed のため）。
