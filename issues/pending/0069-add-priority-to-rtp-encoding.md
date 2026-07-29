# offer の encodings の priority を RTCRtpEncodingParameters に反映する

- Priority: Medium
- Created: 2026-06-10
- Completed:
- Model: deepseek-v4-flash
- Branch: feature/add-priority-to-rtp-encoding
- Polished:

## 目的

offer メッセージの `encodings`（サイマルキャストの各エンコーディング設定）に含まれる `priority` を、送信側の `RTCRtpEncodingParameters` に反映できるようにする。

## 優先度根拠

Medium とする。Sora サーバーが `encodings` のパラメーターとして `priority` を送信することは Sora ドキュメントで確認できているが、本 issue は Pending であり、libwebrtc 上で期待通り動作することが確認できてから対応する。

## 現状

`SignalingOffer.Encoding`（`Sora/Signaling.swift:389`）に `priority` プロパティが存在しない。エンコーディングの更新は `updateOfferEncodings(_:)`（`Sora/PeerChannel.swift:1484`）のみを経由するが、同メソッドでも `priority` は設定していない。

### Sora ドキュメントにおける `priority`

https://sora-doc-canary.shiguredo.jp/SIMULCAST#439977

Sora のサイマルキャスト機能の「映像のエンコーディングパラメーターのカスタマイズ」において、`priority` は以下のように定義されている。

-   オプション
-   string（`very-low` / `low` / `medium` / `high`）
-   https://www.w3.org/TR/webrtc-priority/#dom-rtcrtpencodingparameters-priority
-   **この設定は Chrome でしか利用できません** と注記あり

### W3C 仕様における `priority`

https://www.w3.org/TR/webrtc-priority/#dom-rtcrtpencodingparameters-priority

`RTCRtpEncodingParameters` の `priority` は型 `RTCPriorityType`（`"very-low"` / `"low"` / `"medium"` / `"high"`）、デフォルト値 `"low"` として定義されている。

> The user agent is free to sub-allocate bandwidth between the encodings of an RTCRtpSender.

これはブラウザ内でのエンコーディング間の帯域再配分に関するヒントであり、ブラウザ（User Agent）の裁量で動作する仕様である。

### libwebrtc における対応

libwebrtc の C++ API（`src/api/rtp_parameters.h:607`）では `bitrate_priority`（型: `double`）として実装されている。

```
// "very-low" = 0.5
// "low" = 1.0
// "medium" = 2.0
// "high" = 4.0
double bitrate_priority = kDefaultBitratePriority;  // kDefaultBitratePriority = 1.0
```

ObjC API（`RTCRtpEncodingParameters.h:68`）では `bitratePriority`（型: `double`）として公開されている。

```objc
/** The relative bitrate priority. */
@property(nonatomic, assign) double bitratePriority;
```

`bitratePriority` は `RTCRtpSender.setParameters` 経由で設定可能であり、ビットレートアロケータで参照される。

## 調査結果

| 項目 | 内容 |
|---|---|
| W3C `RTCRtpEncodingParameters.priority` 型 | `RTCPriorityType`（`very-low` / `low` / `medium` / `high`） |
| W3C デフォルト値 | `"low"` |
| W3C 動作 | User Agent の裁量で帯域再配分（ブラウザ前提の仕様） |
| libwebrtc ObjC プロパティ | `bitratePriority` (`double`) |
| libwebrtc C++ フィールド | `bitrate_priority` (`double`) |
| libwebrtc デフォルト値 | `kDefaultBitratePriority` = `1.0` |
| 値の対応 | `very-low` → `0.5`, `low` → `1.0`, `medium` → `2.0`, `high` → `4.0` |
| `RTCRtpEncodingParameters` の関連プロパティ | `bitratePriority` (`double`) と `networkPriority` (`RTCPriority`) は独立した別プロパティ |
| Sora ドキュメントの記載 | `priority` はオプション・string（`very-low` / `low` / `medium` / `high`）。**Chrome でのみ利用可能** と注記 |
| 実装の状態 | Sora iOS SDK では未対応 |

### `networkPriority` (issue 0008) との比較

`networkPriority` は DSCP マーキングという明確な効果があり、`RTCConfiguration.enableDscp` と組み合わせて機能するため実装意義が明らかである。一方 `priority` はブラウザの内部帯域配分のヒントであり、ネイティブ SDK で値をそのまま `bitratePriority` に設定しても libwebrtc がブラウザと同等に動作するか不透明である。

## Pending 理由

以下の点が不明なため、本 issue は Pending とする。

1. **ブラウザ仕様とネイティブ SDK の前提の違い**: W3C の `priority` はブラウザ（User Agent）がエンコーディング間で帯域を再配分する際のヒントとして設計されている。Sora ドキュメントでも **Chrome でのみ利用可能** と注記されている。一方 Sora iOS SDK は libwebrtc を通じて直接 `RTCRtpSender.setParameters` を呼び出すネイティブ実装であり、ブラウザと同じ挙動になるか（また Sora サーバーが想定する挙動と一致するか）確認が必要。
2. **bitrate_priority 設定の実影響の確認不足**: libwebrtc の `bitrate_priority` はビットレートアロケータで参照されるが、サイマルキャスト時の実際の帯域配分にどの程度影響するか、Sora のユースケースで意味があるかが確認できていない。

上記が確認できた時点で Pending を解除し、本 issue の実装に着手する。

## 設計方針

参考として、対応する場合の設計方針を記載する。

1. `SignalingOffer.Encoding` に `priority: Double?` プロパティを追加する。JSON のキー名は `priority` とし、値は文字列（`"very-low"` / `"low"` / `"medium"` / `"high"`）で受け取り、`Double` に変換して保持する。
2. `Encoding: Codable` の `CodingKeys` に `priority` を追加し、`init(from:)` で文字列を `Double` に変換する。変換対応は `"very-low"` → `0.5`、`"low"` → `1.0`、`"medium"` → `2.0`、`"high"` → `4.0`。未知の文字列は `nil` として無視する。
3. `updateOfferEncodings(_:)`（`Sora/PeerChannel.swift:1484`）に `bitratePriority` の反映を追加する。`encoding.priority` が `nil` でない場合のみ `oldEncoding.bitratePriority = value` を設定する。
4. `rtpEncodingParameters`（`Sora/Signaling.swift:412`）にも `bitratePriority` の反映を追加する。
5. 後方互換性: プロパティはオプショナルとし、値がない場合は何も設定しない。既存挙動を変えない。

## テスト方針

Pending 解除後に定義する。

## 完了条件

- `SignalingOffer.Encoding` に `priority: Double?` プロパティが追加されること。
- `Encoding: Codable` のデコード処理で `priority` が `decodeIfPresent` され、文字列から `Double` に変換されること。
- `updateOfferEncodings(_:)` で `priority` が `RTCRtpEncodingParameters.bitratePriority` に反映されること。
- `rtpEncodingParameters` でも `bitratePriority` が設定されること。
- 値が存在しない場合は従来どおり `bitratePriority` を変更しないこと。

## 解決方法

## Pending 解除条件

- ブラウザと同等に動作すること（`RTCRtpSender.setParameters` での設定とビットレートアロケータへの反映）が確認されたこと。
- Sora の iOS SDK において、`priority` の設定が映像の品質や帯域配分に実際に影響することが確認されたこと。
