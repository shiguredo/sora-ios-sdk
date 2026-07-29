# HTTP Proxy 対応 Phase 2（OS 設定の自動参照）

- Priority: Low
- Created: 2026-06-06
- Completed:
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
