# 非推奨化した API を SDK 内部で使い続けないようにする

- Created: 2026-09-10
- Completed: {YYYY-MM-DD}
- Branch: feature/refactor-remove-deprecated-api-internal-usage
- Polished: 2026-09-16

## 目的

SDK が非推奨化した `Configuration.spotlightEnabled` と `TLSSecurityPolicy` / `ICEServerInfo.tlsSecurityPolicy` を SDK 内部で使い続けることで発生する deprecation 警告をなくし、内部の利用経路を非推奨でない API へ揃える。

## 現状

- `PeerChannel.makeSignalingConnect` のスポットライト参照は解消済みである。`0102` により `ConnectionConfigurationSnapshot.isSpotlightEnabled`（`Configuration.isSpotlightEnabled` の写し）を使う形へ移行しており、本 issue での変更は不要。
- `ICEServerInfo.tlsSecurityPolicy` の内部読み取りは `Sora/ConnectionConfigurationSnapshot.swift` の `ICEServerSnapshot.init(_ info: ICEServerInfo)` の 1 か所だけが残っている（`info.tlsSecurityPolicy == .insecure`）。
- `ICEServerInfo` の非推奨でないイニシャライザ（`init(urls:userName:credential:)`）が `self.tlsSecurityPolicy = .secure` と非推奨の既定値へ依存している（`Sora/ICEServerInfo.swift`）。
- `ICEServerInfo.nativeValue(insecure:)` と `ICEServerInfo.usesVerifiedTURNTLS` は `0102` で `ICEServerSnapshot` へ移設済みであり、`TLSSecurityPolicy.nativeValue` と `tlsSecurityPolicyTable` は `0102` で削除済みである。本 issue での変更は不要。
- ビルド時に残る deprecation 警告は、上記の `tlsSecurityPolicy` の内部読み取りとイニシャライザ内の参照に由来する。
- 次の非推奨 API の内部利用は本 issue の対象外とする。後方互換のための内部参照や別目的の作業であり、本 issue では扱わない。
  - `Configuration.multistreamEnabled`（`Configuration.isMultistream` と `makeSignalingConnect`）
  - `Configuration.simulcastRid`（`makeSignalingConnect`）
  - `MediaChannelHandlers.onDisconnectLegacy` / `onReceiveSignaling`
  - iOS SDK 由来の deprecation (`allowBluetooth` / `kCFStreamPropertyHTTPSProxyHost` など)
- テスト（`SoraTests/ConfigurationTests.swift` / `SoraTests/PeerChannelConnectEncodingTests.swift`）は後方互換検証のために `spotlightEnabled` を意図的に参照している。`SoraTests/ConnectionConfigurationSnapshotTests.swift` も `ICEServerInfo` の非推奨イニシャライザを意図的に使っている。これらは対象外とする。

## 設計方針

- `ICEServerInfo` は非推奨プロパティに依存しない internal な真値 `isTLSInsecure: Bool` を持ち、公開 `tlsSecurityPolicy` はこの Bool へ委譲する computed property（`get` / `set`）として残し、後方互換を維持する。非推奨でないイニシャライザは `isTLSInsecure = false` を直接設定し、非推奨イニシャライザ（`init(urls:userName:credential:tlsSecurityPolicy:)`）も引数を内部 Bool へ写す。
- `ICEServerSnapshot.init(_ info: ICEServerInfo)` は `info` の内部 Bool を copy し、`tlsSecurityPolicy` の読み取りを無くす。`ICEServerSnapshot.nativeValue(insecure:)` の `tlsCertPolicy`（`insecure || isTLSInsecure` のとき `.insecureNoCheck`）と `usesVerifiedTURNTLS` の判定は変更しない。
- `TLSSecurityPolicy` の公開 enum 自体は後方互換のため残す。対応表と `nativeValue` の削除は `0102` で完了済みであり、本 issue では追加の削除を行わない。
- 公開 API の挙動を変えない。

## 変更対象

- `Sora/ICEServerInfo.swift`：内部 `isTLSInsecure` の追加、`tlsSecurityPolicy` の computed property 化、イニシャライザの内部 Bool 設定への変更
- `Sora/ConnectionConfigurationSnapshot.swift`：`ICEServerSnapshot.init(_ info: ICEServerInfo)` の `tlsSecurityPolicy` 参照を内部 Bool へ変更
- `CHANGES.md`：`### misc` への追記

## 完了条件

- 本 issue が対象とする `spotlightEnabled` と `TLSSecurityPolicy` / `ICEServerInfo.tlsSecurityPolicy` に由来する SDK 内部の deprecation 警告が Sora ターゲットのビルドで出ない。
- SDK 内部でこれらの非推奨 API を参照しない。
- 公開 API の後方互換と挙動を維持する。`ICEServerInfo.tlsSecurityPolicy` の読み書き、`ICEServerSnapshot.nativeValue(insecure:)` が生成する `RTCIceServer.tlsCertPolicy`、`ICEServerSnapshot` / `WebRTCConfigurationSnapshot` の `usesVerifiedTURNTLS` の挙動を変えない。
- 既存テストがすべて成功する。テストが意図的に参照する非推奨 API は対象外とする。
- `CHANGES.md` の `### misc` に追記すること。ユーザー影響がない場合はその旨を明記する。

## 関連 issue

- `0065`：`Configuration.insecure` を追加した。`TLSSecurityPolicy` の非推奨化と `usesVerifiedTURNTLS` の後方互換の前提を定めた。
- `0030`：`ICEServerInfo` の公開プロパティとイニシャライザを変更する別スコープ。`Sora/ICEServerInfo.swift` を競合するため着手順序に注意する。
- `0102`：完了済み。`ICEServerInfo.nativeValue(insecure:)` / `usesVerifiedTURNTLS` を `ICEServerSnapshot` へ移設し、`TLSSecurityPolicy.nativeValue` / `tlsSecurityPolicyTable` を削除した。`ICEServerSnapshot.isTLSInsecure` は本 issue が導入する `ICEServerInfo` の内部 Bool の写しとして残っているため、移設済みの箇所は変更しない。

## 解決方法
