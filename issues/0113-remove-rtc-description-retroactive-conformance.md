# WebRTC enum の retroactive conformance を削除する

- Created: 2026-08-27
- Completed:
- Branch: feature/remove-rtc-description-retroactive-conformance
- Polished:
- Updated: 2026-08-27

## 目的

imported type である WebRTC enum を imported protocol の `CustomStringConvertible` へ retroactive conformance させる実装を削除する。

WebRTC 側が将来同じ conformance を追加した場合の衝突を避け、Swift 6.3 の retroactive conformance warning と未知 enum value による `fatalError` をなくす。

## 現状

次の 3 ファイルは、合計 6 つの imported type を `CustomStringConvertible` に準拠させている。

- `Sora/Extensions/RTC+Description.swift`
  - `RTCSignalingState`
  - `RTCIceConnectionState`
  - `RTCIceGatheringState`
- `Sora/DataChannel.swift`
  - `RTCDataChannelState`
- `Sora/PeerChannel.swift`
  - `RTCDegradationPreference`
  - `RTCPriority`

Swift 6.3 は、別 module の型を別 module の protocol に準拠させると、型の提供元が将来同じ準拠を追加した際に動作が衝突する可能性を warning として報告する。

現在の CI は warnings-as-errors ではないため通過するが、`0108` で SDK target を warnings-as-errors にすると失敗要因になる。

このうち `RTC+Description.swift` の 3 つの `description` は、`@unknown default` で `fatalError("unknown state")` を実行する。libwebrtc に新しい enum case が追加された場合、状態をログへ出力しただけでアプリが crash する。残る 3 型はすでに非 crash の fallback 文字列を返す。

この conformance は public module に含まれるため、直ちに削除すると利用者が `CustomStringConvertible` 準拠を前提としている場合に source / behavior compatibility へ影響する。

`0070` は WebRTC C API への移行時に `RTC+Description.swift` 自体を削除対象としている。本 issue は C API 移行を待たず、retroactive conformance と crash 経路を解消することを目的とする。

## 設計方針

### SDK 内部の文字列化

- 6 つの enum conformance を、SDK internal の formatter function または wrapper property へ置き換える。
- `PeerChannel`、`DataChannel`、`MediaChannel` のログおよびエラー文字列は internal formatter を明示的に呼ぶ。
- `RTCRtpParameters.description` 内の degradation preference 文字列化も internal formatter を使用する。
- 未知 value は既存の fallback を維持するか、`"unknown"` と raw value 等の診断可能な情報を返し、`fatalError` を呼ばない。
- formatter は state を変更しない pure function とする。

### 互換性

- 現行 release 系で conformance の即時削除が許容できない場合は、一時的に `@retroactive` を明記して warning を抑止する。
- `@retroactive` は最終対応ではなく、次期 major version または `0070` の該当 phase で conformance を削除する。
- 削除時期と影響を API baseline と consumer fixture で確認する。
- conformance 削除後も、SDK のログ文字列が既存の既知 case で変わらないようにする。

### `0070` との関係

- 本 issue が先に完了した場合は、`0070` で 6 つの conformance の撤去と formatter 移行を重複実装しない。
- `RTCSessionDescription.sdpDescription` の移行と `RTC+Description.swift` 自体の削除は、引き続き `0070` で扱う。
- `0070` が先に該当型を撤去する場合は、その変更で 6 型すべての完了条件を満たしているか確認する。

## スコープ外

- `RTCSessionDescription.sdpDescription` は retroactive protocol conformance ではないため、本 issue では削除しない。
- WebRTC C API への移行は `0070` で扱う。
- ログレベルやログ形式全体の変更は行わない。
- 他の enum の Sendable 対応は別 issue とする。

## テスト方針

モックやスタブは使用しない。

- 6 型の既知の全 enum case を internal formatter へ入力し、既存の description 文字列と一致することを確認する。
- `@unknown default` 相当の将来 case を現在の SDK だけで生成できない場合は、状態系 3 型の formatter が `fatalError` を含まないことを静的に確認する。
- `SignalingOfferEncodingTests.testRTCPriorityDescription` は、retroactive conformance ではなく internal formatter を検証するテストへ変更する。
- 実 PeerConnection の signaling / ICE state change log が従来どおり出力されることを確認する。
- 実 DataChannel の ready state log と `MediaChannel.sendMessage(label:data:)` のエラー文字列が従来どおりであることを確認する。
- Swift 6.3 の warnings-as-errors で retroactive conformance warning が 0 件になることを確認する。
- `0107` の consumer fixture と API baseline で互換性への影響を確認する。
- テストには、imported type へ conformance を追加しない理由を日本語コメントで明記する。

## 完了条件

- 6 つの WebRTC enum に対する `CustomStringConvertible` conformance が削除されていること。
- SDK 内のログが internal formatter を使用すること。
- internal formatter が未知 value で `fatalError` を呼ばないこと。
- Swift 6.3 の retroactive conformance warning が 0 件であること。
- 既知の enum case に対するログ文字列が意図せず変わっていないこと。
- public conformance 削除の互換性影響が consumer fixture と API baseline で確認されていること。
- `0070` の削除計画と重複していないこと。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
