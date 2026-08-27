# Sendable な RPC API を追加する

- Created: 2026-08-27
- Completed:
- Branch: feature/add-sendable-rpc-api
- Polished:

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

- `0094`: RPC pending、invalidate、timeout、Task cancellation の終端競合を修正する。

本 issue は RPC lifecycle が厳密に 1 回終端する状態を前提に、公開 data model の Sendable 対応だけを追加する。

## 設計方針

### 新しい RPC method 契約

- `Params: Encodable & Sendable` と `Result: Decodable & Sendable` を要求する新しい public protocol を追加する。
- 既存 `RPCMethodProtocol` の制約は変更せず、互換 API として維持する。
- 新旧 protocol の両方へ準拠した型で overload が曖昧にならない API 名または明示的な overload 設計を採用する。
- SDK 組み込みの RPC params / result は deep-safe であることを確認したうえで新 protocol に対応する。

### response の越境

- DataChannel callback で受け取った RPC response は、callback executor 上で immutable な `Data` として保持する。
- `Any` の JSONSerialization container を executor 境界へ渡さない。
- request ID と JSON-RPC version は Sendable な値として分離する。
- `Result` への decode は、RPC owner または caller へ返す直前の明確な executor 上で行う。
- 新しい `RPCResponse<Result: Sendable>` を Sendable にする。

### server error

- server error の追加情報は、`Data?` または recursive に Sendable な JSON value で表現する。
- 既存 `RPCErrorDetail.data: Any?` の型は変更せず、Swift 6 API 用の新しい error detail を追加する。
- 新 API が返す Error 全体について、associated value を含めて deep Sendable であることを確認する。
- `Any` を保持したまま `@unchecked Sendable` を付与しない。

### cancellation と exactly-once

- 新 async API は `0094` の pending 終端機構を利用する。
- Task cancellation 時は RPC pending を取り消し、response / timeout / disconnect と競合しても 1 回だけ終了する。
- decode 完了後に cancellation が発生した場合の優先順位を決め、API documentation に記載する。

### 互換性

- 既存 `RPCMethodProtocol`、`RPCResponse`、`RPCErrorDetail`、`MediaChannel.rpc` を削除・変更しない。
- 新 API の追加前後を `0107` の consumer fixture と API baseline で検証する。
- 旧 API の deprecation は本 issue に含めない。

## スコープ外

- RPC pending lifecycle の bug は `0094` で扱う。
- `Configuration` 内の metadata / `Any` は `0102` で扱う。
- 既存 RPC API の削除は次期 major version の別 issue とする。
- RPC method 自体の追加・変更は行わない。

## テスト方針

モックやスタブは使用しない。

- 実 DataChannel と実 Sora RPC を使い、SDK 組み込み RPC method の成功・server error を検証する。
- 利用者定義の Sendable params / result を `0107` の consumer fixture から呼び出せることを compile で確認する。
- nested object、array、null、scalar を含む result と error data を実 JSON で検証する。
- mutable reference type を新 protocol の associated type に指定した場合、Sendable を満たさなければ compile できないことを fixture で確認する。
- Task cancellation、timeout、disconnect、response を競合させ、すべての Task が 1 回だけ終端することを確認する。
- raw response の `Data` が decode 完了後に残留しないことを確認する。
- テストには、`Any` を executor 境界へ渡さない理由を日本語コメントで明記する。

## 完了条件

- Sendable 制約を持つ新しい RPC method protocol が存在すること。
- 新しい RPC response と server error detail が deep Sendable であること。
- 新しい RPC 経路が `Any` と `RPCRawResponse: @unchecked Sendable` を使用しないこと。
- JSONSerialization container を executor 境界へ渡さず、immutable `Data` または Sendable JSON value を利用すること。
- Task cancellation、response、timeout、disconnect が競合しても厳密に 1 回終端すること。
- 既存 RPC protocol と API の source compatibility が維持されること。
- overload ambiguity がないことを consumer fixture で確認していること。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
