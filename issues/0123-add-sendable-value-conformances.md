# immutable な公開 value type に Sendable 準拠を追加する

- Created: 2026-08-27
- Completed:
- Branch: feature/add-sendable-value-conformances
- Polished:

## 目的

immutable または deep-safe にできる公開 value type へ checked `Sendable` conformance を追加し、Swift 6 consumer が actor / Task 境界で SDK の値を利用できるようにする。

mutable reference、`Any`、raw WebRTC object を含む型を unchecked にして一括対応しない。

## 現状

`Proxy`、`Role`、`Rid`、`AudioCodec`、`VideoCodec` など一部の公開 value type は `Sendable` に対応している。

一方、次のような pure value type には `Sendable` が付与されていない。

- `ConnectionState`
- `MediaConstraints`
- `DegradationPreference`
- `AudioOutput`
- `LogType`
- `LogLevel`
- `Log`
- `VideoViewConnectionMode`
- `WebSocketMessage`
- `ForwardingFilterRuleField`
- `ForwardingFilterRuleOperator`
- `ForwardingFilterAction`
- `ForwardingFilterRule`

`AudioMode` など Apple SDK の imported type を associated value に持つ型は、その構成要素の Sendable import 状態を確認する必要がある。

`Configuration`、`WebRTCConfiguration`、`ScreenCaptureSettings`、`Signaling` DTO、`Statistics`、`VideoFrame` などは mutable reference、closure、`Any`、raw WebRTC object を含むため、本 issue で単純に Sendable を付与できない。

## 設計方針

- public enum / struct を機械的に一覧化し、stored property と associated value を再帰的に確認する。
- deep-safe な型だけへ checked `Sendable` conformance を追加する。
- conditional conformance が必要な generic type は、generic parameter に `Sendable` を要求しても既存利用者を壊さないか API baseline で確認する。
- Apple SDK / WebRTC の imported type を含む場合は、採用 toolchain の module interface で Sendable conformance を確認する。
- mutable class、closure、`Any`、`NSObject`、raw WebRTC object を含む型へ `@unchecked Sendable` を付与しない。
- unsafe な型は、`0102`、`0109`、`0110`、`0120` などの snapshot / v2 API で扱う。
- public conformance の追加による利用者側の retroactive conformance 競合を変更履歴に明記する。

## テスト方針

モックやスタブは使用しない。

- `0107` の consumer fixture で各対応型を actor と Task の間で受け渡す。
- strict concurrency と warnings-as-errors で compile する。
- Codable / CustomStringConvertible / Equatable など既存 conformance の挙動が変わらないことを確認する。
- API baseline で conformance 追加以外の公開 API 変更がないことを確認する。
- unsafe な型が誤って Sendable allowlist に入っていないことを静的に検査する。

## 完了条件

- deep-safe な公開 value type の Sendable 対応一覧が確定していること。
- 対応一覧の全型が checked `Sendable` に準拠していること。
- `@unchecked Sendable` を value type の一括対応に使用していないこと。
- unsafe な型が snapshot / v2 API の関連 issue へ明確に分離されていること。
- consumer fixture と API baseline の検査が成功すること。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
