# 利用者が actor / Task 境界へ渡せる公開 Sendable 設定型を追加する

- Created: 2026-09-15
- Completed:
- Priority: Medium
- Branch: feature/add-sendable-configuration-api
- Polished: 2026-09-16

## 目的

Swift 6 言語モードの利用者が、接続設定を actor / Task 境界へ安全に渡せる公開型を追加する。

`0123` は `Configuration` を「`Sendable` を付与できない型」に分類し、unsafe な型の受け皿を `0102` / `0109` / `0110` / `0120` の snapshot / v2 API としている。しかし `0102` が導入する `ConnectionConfigurationSnapshot` は internal であり、`0109` / `0110` / `0120` は RPC / event / statistics が対象で、公開 Sendable な設定型を提供する issue が存在しない。このままだと、利用者が設定値を actor / Task 境界へ渡す手段が無いままになる。

## 現状

`Sora/Configuration.swift` の `Configuration` は次の理由で `Sendable` にできない。

- `signalingConnectMetadata` / `signalingConnectNotifyMetadata` / `audioOpusParams` / `videoVp9Params` / `videoAv1Params` / `videoH264Params` / `videoH265Params` の `Encodable?`
- `dataChannels: Any?`
- `forwardingFilter` / `forwardingFilters` と `ForwardingFilter.metadata: Encodable?`
- 可変 class の `ICEServerInfo`、`webSocketChannelHandlers`、`mediaChannelHandlers`
- raw WebRTC object の `audioDevice`

`0102` は接続開始時にこれらを internal な `ConnectionConfigurationSnapshot` へ写し取る (handler bag と `audioDevice` は snapshot へ含めず、明示引数として引き渡す) が、internal のため通常の consumer は `import Sora` から参照できない。`0107` の consumer package は `@testable` と `@preconcurrency` を禁止しており、internal 型を検証対象にできない。

## 設計方針

- 内部型である `ConnectionConfigurationSnapshot` をそのまま公開しない。内部都合の変更が公開 API の互換性を縛るためである。
- 公開設定型のフィールドは `Configuration` の全 stored property を対象とし、`0102` が確定した snapshot のフィールド分類 (そのまま値で持つ / 変換して持つ / 含めない) を再利用する。分類の内訳と根拠は `0102` を引き継ぐ。
- `Encodable?` の metadata 系 7 個 (`signalingConnectMetadata` / `signalingConnectNotifyMetadata` / `audioOpusParams` / `videoVp9Params` / `videoAv1Params` / `videoH264Params` / `videoH265Params`)、`ForwardingFilter.metadata`、`Any?` の `dataChannels` は公開 `JSONValue?` として保持する。`Sora/JSONValue.swift` の `JSONValue` は `0102` の完了により internal のままなので、公開する判断は `0157` が行い、本 issue は `0157` の完了を前提とする。
- `WebRTCConfiguration` と `ForwardingFilter` は、`Sendable` な既存公開型 (`MediaConstraints` / `DegradationPreference` / `SDPSemantics` / `ICETransportPolicy` / `ForwardingFilterRule` 系。`0123` で `Sendable` になった型と以前から `Sendable` だった型の混在である) をそのまま保持し、mirror 型を定義しない。可変 class の `ICEServerInfo` だけを deep Sendable な公開値型へ写す (URL / username / credential / TURN-TLS ポリシーのフィールド分類は `0102` の `ICEServerSnapshot` と同じ)。
- 公開設定型は deep Sendable な値だけで構成し、handler (`webSocketChannelHandlers` / `mediaChannelHandlers`) を含めない。event の購読は `0110` の Sendable event API が担う。`audioDevice` は internal のため公開設定型では表現せず、`requiresStereoAudioSDP` は `audioDevice` が公開利用者では常に nil であることから `audioStereoOutputEnabled` と同じ値として扱う。
- `Sora.connect` に新しい overload を追加し、既存の `connect(configuration:webRTCConfiguration:handler:)` は維持する。新 overload は公開設定型から `ConnectionConfigurationSnapshot` を直接構築し、metadata / `dataChannels` は公開設定型が保持する `JSONValue` をそのまま写す。`Configuration` へ復元してから `0102` の変換を再実行する経路は採らない (`dataChannels` の変換が `JSONSerialization` なため、`JSONValue` を受理せず失敗する)。公開設定型から `Configuration` への復元は `MediaChannel.configuration` の互換のためにだけ用意し、snapshot 生成には使わない。
- 既存 `Configuration` から公開設定型への変換経路を用意し、利用者が段階的に移行できるようにする。変換は metadata などの encode に失敗し得るため、失敗時のエラー型と `SoraError.configurationError` への写像は `0157` の `JSONValue` 公開時の決定に合わせる (公開型に SDK 固有のエラー写像と理由文字列を抱え込ませない)。
- `0102` の完了を前提とする。`0102` が確定する snapshot のフィールド分類を再利用する。

## 前提となる issue

- `0102` (完了 2026-09-16): 内部 snapshot の型と変換。フィールド分類を本 issue の設計に再利用する。
- `0110`: handler を Sendable な event API として提供する。公開設定型から handler を除外する前提である。
- `0123` (完了 2026-09-15): 公開 value type への `Sendable` 準拠。公開設定型がそのまま保持する型の前提である。
- `0107`: consumer package による strict concurrency 検証の基盤。
- `0157`: `JSONValue` の public 化。metadata / `dataChannels` / `ForwardingFilter.metadata` の表現に使う。

### 順序調整

- `0157` の完了後に着手する。公開設定型が保持する公開 `JSONValue` が存在するためである。
- 実装は `0107` の完了前に進められるが、consumer package ができてからでないと完了条件の compile scenario 検証を行えない。

## スコープ外

- `0109` / `0110` / `0120` の API (RPC / event / statistics) の設計と実装。
- `0153` が扱う、`Sora.connect` の `webRTCConfiguration` 引数と `Configuration.webRTCConfiguration` の一本化。本 issue は新 overload の追加のみで、既存 overload の引数は変更しない。
- 既存 `Configuration` の非推奨化と削除 (後方互換のない変更)。
- `0157` が扱う、`JSONValue` の public 化と変換エラーの `SoraError` への写像の分離。

## 完了条件

- 公開 Sendable な設定型が追加され、利用者が actor / Task 境界で設定値を渡せること。
- 設定型が handler を含まず、deep Sendable であること。
- `Configuration` から公開設定型への変換で、metadata / `dataChannels` / codec 別 params / `ForwardingFilter` / WebRTC 設定の値が失われておらず、公開設定型から `Configuration` への復元で同じ接続設定になること。
- `0107` の consumer package へ公開設定型の compile scenario を追加し、`SWIFT_STRICT_CONCURRENCY=complete` と warnings-as-errors により compile できること。
- 既存の `Configuration` と `Sora.connect` の公開 API が維持されていること。
- `CHANGES.md` に `[ADD]` として追記していること。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
