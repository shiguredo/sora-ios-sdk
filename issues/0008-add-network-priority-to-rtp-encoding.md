# offer の encodings の networkPriority を RTCRtpEncodingParameters に反映する

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-network-priority-to-rtp-encoding
- Polished: 2026-06-05

## 目的

offer メッセージの `encodings`（サイマルキャストの各エンコーディング設定）に含まれる `networkPriority` を、送信側の `RTCRtpEncodingParameters` に反映できるようにする。現状の SDK はこの値を読み捨てており、指定したネットワーク優先度（DiffServ Code Point）がエンコーディングに反映されない。

## 依存関係

本 issue と `0031-investigate-offer-encodings` は、いずれも `updateOfferEncodings(_:)` を変更する。本 issue は同メソッドに `networkPriority` の反映を追加し、`0031-investigate-offer-encodings` は同メソッドのワークアラウンド除去を検討するため、実装が衝突する。優先度は本 issue (Medium) が `0031` (Low) より高いため本 issue を先に進め、`0031` はその差分に追従する。`0031` がマージ済みか否かを着手前に確認すること。

## 優先度根拠

Medium とする。`encodings` に `networkPriority` が含まれる場合に SDK がこれを反映しないと、指定が無視され意図したネットワーク優先度が適用されない。一方で `maxBitrate` / `scaleResolutionDownBy` などと同様に既存の反映処理へ 1 項目追加するだけのため対応範囲は限定的であり、既存機能の不具合ではないため High ではない。

## 現状

`SignalingOffer.Encoding`（`Sora/Signaling.swift:389`）に `networkPriority` プロパティが存在しない。`Codable` 実装（`Sora/Signaling.swift:1069`）の `CodingKeys` にも `networkPriority` がなく、デコード処理にも含まれていない。

エンコーディングの更新は `updateOfferEncodings(_:)`（`Sora/PeerChannel.swift:1484`）のみを経由する。`Sora/Signaling.swift:412` の `rtpEncodingParameters` computed property は公開 API として定義されているが SDK 内部からは呼ばれておらず、実際の反映は `updateOfferEncodings(_:)` だけを通じて行われる。同メソッドでも `networkPriority` は設定していない。

WebRTC 側には `RTCRtpEncodingParameters.networkPriority`（型: `RTCPriority`、値: `RTCPriorityVeryLow` / `RTCPriorityLow` / `RTCPriorityMedium` / `RTCPriorityHigh`）が存在する。現行の libwebrtc バージョン（`Package.swift` の `libwebrtcVersion`）において `RTCRtpEncodingParameters.networkPriority` が公開 API として利用可能であることを、xcframework のヘッダーで実装前に確認すること。

## 設計方針

1. `SignalingOffer.Encoding` に `networkPriority: RTCPriority?` プロパティを追加する。`encodings` に含まれない場合を考慮しオプショナルとする。
2. `Encoding: Codable` の `CodingKeys` に `networkPriority` を追加する（raw value なし）。`JSONDecoder()` は `keyDecodingStrategy` を設定していないためキャメルケースがそのまま JSON キーになる。既存の `maxBitrate` / `maxFramerate` 等が raw value なしのキャメルケースで Sora サーバーと実際に通信できていることが根拠であり、`networkPriority` も同様にキャメルケースで送られてくると判断する。`init(from:)` で生文字列を `let rawNetworkPriority = try container.decodeIfPresent(String.self, forKey: .networkPriority)` でデコードしてから `RTCPriority` へ変換して `networkPriority` に設定する。変換実装は switch 文を主方針とする（`RTCPriority` は Obj-C enum のため `Equatable & Sendable` 制約が自動付与されない可能性が高く `PairTable<String, RTCPriority>` が使えない可能性がある。コンパイルが通れば `simulcastRidTable` 等と同様に `PairTable` を使ってもよい）。文字列と `RTCPriority` の対応は `"very-low"` → `.veryLow`、`"low"` → `.low`、`"medium"` → `.medium`、`"high"` → `.high` とし、それ以外の文字列は `nil` として無視する。
3. `updateOfferEncodings(_:)`（`Sora/PeerChannel.swift:1484`）に `networkPriority` の反映を追加する。`encoding.networkPriority` が `nil` でない場合のみ `oldEncoding.networkPriority = value` を設定する。ログは `RTCPriority` が Obj-C enum のため `\(value)` で整数値が出力されて可読性が低いため、逆変換ヘルパー（`RTCPriority → String`）を実装して `Logger.debug(type: .peerChannel, message: "networkPriority: \(priorityString)")` の形式で追加する。`SignalingOffer.Encoding` に生文字列の追加プロパティは設けない。
4. `rtpEncodingParameters`（`Sora/Signaling.swift:412`）にも `networkPriority` の反映を追加する。SDK 内部からは呼ばれていないが公開 API として外部利用者が使用する可能性があるため追加する。なお同 property では `active`（`params.isActive`）が設定されていないという既存の非対称性があるが、`active` の修正は本 issue のスコープ外とする（`updateOfferEncodings(_:)` での `active` 反映は別箇所で行われており、必要であれば別途独立した issue として対応する）。
5. 後方互換性: プロパティはオプショナルとし、値がない場合は何も設定しない。既存挙動を変えない。

## テスト方針

モック・スタブは使用しない。

- JSON デコードテスト: `networkPriority` を含む JSON 文字列をデコードし `SignalingOffer.Encoding.networkPriority` に正しい `RTCPriority` 値が設定されることを検証する。検証ケース: `"very-low"` / `"low"` / `"medium"` / `"high"` の各値（計 4 件）、フィールドなし（`nil` 期待）、未知の文字列（`nil` 期待）の計 6 ケース。
- `rtpEncodingParameters` テスト: `networkPriority` を設定した `SignalingOffer.Encoding` から `rtpEncodingParameters` を生成し、`RTCRtpEncodingParameters.networkPriority` に正しい値が設定されていることを `RTCRtpEncodingParameters` の実オブジェクトで検証する。`nil` の場合は xcframework ヘッダーで `RTCRtpEncodingParameters().networkPriority` のデフォルト値を確認し、そのままであることをアサートする。
- テストの追加先は新規ファイル `SoraTests/SignalingOfferEncodingTests.swift` を作成すること（`SoraTests/` 配下に `SignalingOffer.Encoding` 関連テストは存在しない）。

## 完了条件

- `SignalingOffer.Encoding` に `networkPriority: RTCPriority?` プロパティが追加されること。
- `Encoding: Codable` のデコード処理で `networkPriority` が `decodeIfPresent` されること。
- `updateOfferEncodings(_:)` で `networkPriority` が `RTCRtpEncodingParameters` に反映されること（`nil` の場合は設定しない）。
- `rtpEncodingParameters` でも `networkPriority` が設定されること（公開 API としての一貫性）。
- 値が存在しない場合は従来どおり `networkPriority` を変更しないこと。
- テスト方針に記載したテストがすべて通ること。
- `CHANGES.md` の `develop` セクションに `[ADD]` エントリと担当者行を追記すること。

## 解決方法
