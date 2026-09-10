# 非推奨化した API を SDK 内部で使い続けないようにする

- Created: 2026-09-10
- Completed: {YYYY-MM-DD}
- Branch: feature/refactor-remove-deprecated-api-internal-usage
- Polished: 2026-09-10

## 目的

SDK が非推奨化した `Configuration.spotlightEnabled` と `TLSSecurityPolicy` / `ICEServerInfo.tlsSecurityPolicy` を SDK 内部で使い続けることで発生する deprecation 警告をなくし、内部の利用経路を非推奨でない API へ揃える。

## 現状

- `PeerChannel.makeSignalingConnect` が `Configuration.spotlightEnabled` (非推奨) を参照している。`Configuration.isSpotlightEnabled` へ置き換えられる。
- `ICEServerInfo` の内部処理が `tlsSecurityPolicy` (非推奨) を参照している。
- `TLSSecurityPolicy` の対応表 (`tlsSecurityPolicyTable`) と `nativeValue` が内部で非推奨型を参照している。`nativeValue` の呼び出し元は `ICEServerInfo.nativeValue(insecure:)` の 1 か所のみ。
- ビルド時にこれらの deprecation 警告が出る。
- 次の非推奨 API の内部利用は本 issue の対象外とする。後方互換のための内部参照や別目的の作業であり、本 issue では扱わない。
  - `Configuration.multistreamEnabled`（`Configuration.isMultistream` と `makeSignalingConnect`）
  - `Configuration.simulcastRid`（`makeSignalingConnect`）
  - `MediaChannelHandlers.onDisconnectLegacy` / `onReceiveSignaling`
  - iOS SDK 由来の deprecation (`allowBluetooth` / `kCFStreamPropertyHTTPSProxyHost` など)
- テスト (`SoraTests/ConfigurationTests.swift` / `SoraTests/PeerChannelConnectEncodingTests.swift`) は後方互換検証のために `spotlightEnabled` を意図的に参照している。これは対象外とする。

## 設計方針

- `PeerChannel.makeSignalingConnect` は `configuration.isSpotlightEnabled` を使って `Configuration.Spotlight` を組み立てる。`spotlightEnabled` の getter は `isSpotlightEnabled ? .enabled : .disabled` であり、挙動は等価。
- `ICEServerInfo` は非推奨プロパティに依存しない internal な真値 (Bool) を持ち、`nativeValue(insecure:)` はその Bool から `RTCTlsCertPolicy` を決める。公開 `tlsSecurityPolicy` は internal な Bool へ委譲する computed property として残し、後方互換を維持する。
- `tlsSecurityPolicyTable` と `TLSSecurityPolicy.nativeValue` は削除する。`TLSSecurityPolicy` の公開 enum 自体は後方互換のため残す。
- 公開 API の挙動を変えない。

## 変更対象

- `Sora/PeerChannel.swift`: `makeSignalingConnect` の `spotlightEnabled` 参照
- `Sora/ICEServerInfo.swift`: `tlsSecurityPolicy` の内部真値化と `nativeValue(insecure:)`
- `Sora/TLSSecurityPolicy.swift`: `tlsSecurityPolicyTable` と `nativeValue` の削除
- `CHANGES.md`: `### misc` への追記

## 完了条件

- 本 issue が対象とする `spotlightEnabled` と `TLSSecurityPolicy` / `ICEServerInfo.tlsSecurityPolicy` に由来する SDK 内部の deprecation 警告が Sora ターゲットのビルドで出ない。
- SDK 内部でこれらの非推奨 API を参照しない。
- 公開 API の後方互換と挙動を維持する。`ICEServerInfo.tlsSecurityPolicy` の読み書きと `WebRTCConfiguration.usesVerifiedTURNTLS` の挙動を変えない。
- 既存テストがすべて成功する。テストが意図的に参照する非推奨 API は対象外とする。
- `CHANGES.md` の `### misc` に追記すること。ユーザー影響がない場合はその旨を明記する。

## 関連 issue

- `0065`: `Configuration.insecure` を追加した。`TLSSecurityPolicy` の非推奨化と `usesVerifiedTURNTLS` の後方互換の前提を定めた。
- `0030`: `ICEServerInfo` の `nativeValue(insecure:)` とイニシャライザを変更する別スコープ。同じメソッドを編集するため着手順序に注意する。

## 解決方法
