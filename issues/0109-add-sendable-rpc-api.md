# Sendable な RPC API を追加する

- Created: 2026-08-27
- Completed:
- Branch: feature/add-sendable-rpc-api
- Polished: 2026-09-16

## 目的

RPC の parameter、result、server error を actor / Task 境界で安全に扱える、deep Sendable な公開 API を追加する。

既存の `RPCMethodProtocol` と `MediaChannel.rpc` の source compatibility を維持しながら、`Any` と `@unchecked Sendable` に依存しない Swift 6 向け RPC 経路を提供する。

## 現状

`Sora/RPCTypes.swift` の `RPCMethodProtocol` は、associated type に次の制約だけを要求する。

- `Params: Encodable`
- `Result: Decodable`

参照型や mutable state を保持する型でも準拠できるため、RPC の非同期処理を越えて安全に受け渡せる保証がない。

`Sora/RPC.swift` には次の non-Sendable な公開・内部表現がある。

- `RPCErrorDetail.data: Any?`
- `RPCResponse<Result>` に `Result: Sendable` 制約がない。
- `RPCRawResponse.result: Any`
- `RPCRawResponse: @unchecked Sendable`

DataChannel callback で `JSONSerialization` が返した Foundation container を `Any` のまま保持し、checked continuation を通じて async caller へ返している。「読み取り専用として扱う」というコメントだけでは、container 内の参照型と alias の安全性を保証できない。

既存 protocol に直接 `Sendable` 制約を追加すると、利用者が定義した RPC method、params、result の準拠が compile できなくなるため破壊的変更になる。

## 前提となる issue

- `0094` (完了 2026-08-31): RPC pending、invalidate、timeout、Task cancellation の終端競合を修正する。
  - `RPCChannel` は concurrent queue の barrier 配下で `pendings` / `isInvalidated` を保護し、`@unchecked Sendable` で宣言している。
  - Task cancellation は `CancelledRPCIDStore` (NSLock 保護の `Int?` ストア) 経由で `rpcChannel.cancel(identifier:)` を呼び、`finishPending` で厳密に 1 回終端する。
  - `RPCChannel.call` のシグネチャ変更 (戻り値 `Int?`、completion の `Error` 型) は内部 API のみの変更で、public API の source compatibility には影響しない。
- `0107` (open): 外部 consumer package と API baseline。新 API の compile scenario と API baseline 検証は `0107` の完了を前提とする (未完了の場合は先に完了させる)。
- `0157` (実装済み): 既存 `RPCErrorDetail.data` を `Any?` から `JSONValue?` へ変更し、`RPCErrorDetail` を `Sendable` にした。`Sora/JSONValue.swift` の `JSONValue` は public になっている。本 issue はこの状態を前提にし、既存 `RPCErrorDetail` の宣言をさらに変更しない。新 API 用の error detail で JSON value を使う場合は `0157` が公開した `JSONValue` を利用する。
- `0123` (完了 2026-09-15): Sendable を付与できない型の分類と受け皿の整理。RPC の params / result / method enum の Sendable 対応は本 issue の新 API 契約で扱う。

本 issue は RPC lifecycle が厳密に 1 回終端する状態 (`0094`) を前提に、新しい RPC API と、その実現に必要な内部表現 (`RPCRawResponse` の `Any` 排除) の変更を追加する。

- `0094` の `RPCChannel` は barrier + `@unchecked Sendable` の構造を残している。本 issue では actor へ移行せず、barrier 配下の保護を維持したまま response の持ち方を `Data` ベースへ移す。actor 化すると `call()` が同期 API (`MediaChannel.rpc` から同期呼び出しされる) であることを含めて公開 API と `0094` の終端保証へ波及し、本 issue の目的に対して変更が大きくなるため採らない。

## 設計方針

### 新しい RPC method 契約

- `Params: Encodable & Sendable` と `Result: Decodable & Sendable` を要求する新しい public protocol を追加する。
- 既存 `RPCMethodProtocol` の制約は変更せず、互換 API として維持する。
- 新 API の呼び出しメソッドは、既存 `MediaChannel.rpc` とは別名の新メソッドとして追加する (同名 overload にしない)。同名 overload にすると、新旧両方の protocol へ準拠した型 (SDK 組み込み RPC メソッドを含む) の呼び出しが新 overload へ解決されて戻り値の型が変わり、source compatibility を壊す。
- SDK 組み込み RPC メソッドは、新 protocol へも準拠させる。`RequestSimulcastRid` / `RequestSpotlightRid` / `ResetSpotlightRid` は params / result の構成値がすべて Sendable なため、そのまま準拠できる。`PutSignalingNotifyMetadata` / `PutSignalingNotifyMetadataItem` は型パラメータ (`Metadata` / `Value`) が `Encodable` / `Decodable` のみで Sendable を要求していないため、**型パラメータが Sendable の場合に成立する conditional conformance** で準拠させる (既存の準拠と公開 API には影響しない)。

### response の越境

- DataChannel callback で受け取った RPC response は、callback executor 上で immutable な `Data` として保持する。
- `Any` の JSONSerialization container を executor 境界へ渡さない。
- request ID と JSON-RPC version は Sendable な値として分離する。
- `Result` への decode は、RPC owner または caller へ返す直前の明確な executor 上で行う。
- 新 API 用の応答型は、既存 `RPCResponse<Result>` とは別名の新規型として追加し、`Result: Decodable & Sendable` 制約の下で `Sendable` に準拠させる。既存 `RPCResponse` の宣言と準拠は変更しない。

### server error

- server error の追加情報は、`Data?` または recursive に Sendable な JSON value で表現する。JSON value を使う場合は `0157` が公開した `Sora/JSONValue.swift` の `JSONValue` を利用する。
- 既存 `RPCErrorDetail` は本 issue では変更しない (`data` の型変更と `Sendable` 準拠は `0157` で完了している)。新 API 用に、既存 `RPCErrorDetail` とは別名の新しい error detail を追加する。
- 既存 `SoraError.rpcServerError(detail: RPCErrorDetail)` の associated type は変更しないため、新 API の server error は、新 API 用の error detail を associated value に持つ新 API 専用の error 型を追加して返す。既存 `SoraError` への case 追加は行わない (利用者の網羅 switch を壊すため)。timeout / unavailable / closed / encoding / decoding は既存 `SoraError` の対応 case をそのまま利用する。
- 新 API が返す Error 全体について、associated value を含めて deep Sendable であることを確認する。
- `Any` を保持したまま `@unchecked Sendable` を付与しない。

### cancellation と exactly-once

- 新 async API は `0094` の pending 終端機構を利用する。
- Task cancellation 時は RPC pending を取り消し、response / timeout / disconnect と競合しても 1 回だけ終了する。
- decode 完了後に cancellation が発生した場合の優先順位を決め、API documentation に記載する。

### 互換性

- 既存 `RPCMethodProtocol`、`RPCResponse`、`SoraError.rpcServerError(detail:)`、`MediaChannel.rpc` を削除・変更しない (`RPCErrorDetail` の `data` の型と `Sendable` 準拠は `0157` で確定済みで、本 issue は `RPCErrorDetail` をさらに変更しない)。
- 新 API の型名・メソッド名は既存の公開 API と衝突させない。
- 新 API の追加前後を `0107` の consumer package と API baseline で検証する。
- 旧 API の deprecation は本 issue に含めない。

## スコープ外

- RPC pending lifecycle の bug は `0094` (完了済み) で扱った。
- `Configuration` 内の metadata / `Any` は `0102` (完了済み) で扱った。
- 既存 RPC API の削除は次期 major version の別 issue とする。
- RPC method 自体の追加・変更は行わない。

## テスト方針

モックやスタブは使用しない。

- 実 DataChannel と実 Sora RPC を使い、SDK 組み込み RPC method の成功・server error を検証する。
- 利用者定義の Sendable params / result を `0107` の consumer package から呼び出せることを compile で確認する。
- nested object、array、null、scalar を含む result と error data を実 JSON で検証する。
- mutable reference type を新 protocol の associated type に指定した場合、Sendable を満たさなければ compile できないことを consumer package で確認する。
- Task cancellation、timeout、disconnect、response を競合させ、すべての Task が 1 回だけ終端することを確認する。
- raw response の `Data` が decode 完了後に残留しないことを確認する。
- テストには、`Any` を executor 境界へ渡さない理由を日本語コメントで明記する。

## 完了条件

- Sendable 制約を持つ新しい RPC method protocol が存在すること。
- 新しい RPC response、server error detail、新 API 専用の error 型が deep Sendable であること。
- 新しい RPC 経路が `Any` と `RPCRawResponse: @unchecked Sendable` を使用しないこと。
- JSONSerialization container を executor 境界へ渡さず、immutable `Data` または Sendable JSON value を利用すること。
- Task cancellation、response、timeout、disconnect が競合しても厳密に 1 回終端すること。
- 既存 RPC protocol と API の source compatibility が維持されること。
- 新 API が既存 `MediaChannel.rpc` と別名で提供され、新旧両方の protocol へ準拠した型の呼び出しで曖昧さや解決先の変化が発生しないことを consumer package で確認していること。
- SDK 組み込み RPC メソッドが新 protocol へ準拠し、`PutSignalingNotifyMetadata` / `PutSignalingNotifyMetadataItem` は型パラメータが非 Sendable でも既存の準拠を壊さないこと。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
