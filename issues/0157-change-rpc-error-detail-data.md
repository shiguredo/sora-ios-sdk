# `RPCErrorDetail.data` を deep-Sendable な表現に変更する

- Created: 2026-09-15
- Completed:
- Priority: Medium
- Branch: feature/change-rpc-error-detail-data
- Polished:

## 目的

`SoraError.rpcServerError(detail:)` が運ぶ `RPCErrorDetail.data: Any?` を deep-Sendable な表現へ変更し、`SoraError` に出ている Swift 6 の concurrency 警告を解消する。

採用 toolchain の stdlib は `public protocol Error : Swift.Sendable` を宣言しているため、`Error` に準拠する `SoraError` は暗黙に `Sendable` とみなされる。`SoraError` は `case rpcServerError(detail: RPCErrorDetail)` を持ち、`RPCErrorDetail` は `public let data: Any?` を持つ。このため、`SoraError` の `rpcServerError(detail:)` の associated value が non-Sendable な `RPCErrorDetail` であるという趣旨の警告 (`associated value 'rpcServerError(detail:)' of 'Sendable'-conforming enum 'SoraError'` と `non-Sendable type 'RPCErrorDetail'` を含む) が現行ソースで出ている。

`SoraError` は `throws` で actor 境界を越えるため、この警告は「`Sendable` と宣言されている型が non-Sendable な payload を運ぶ」という実際の欠陥を示している。`0108` が `Package.swift` を Swift 6 language mode へ移行し、`0118` が warnings-as-errors を導入すると build が失敗する。

## 現状

`Sora/RPC.swift` の `RPCChannel` は DataChannel で受け取った JSON を `JSONSerialization` で読み、`error["data"]` をそのまま `RPCErrorDetail.data` へ入れている。

```swift
let detail = RPCErrorDetail(code: code, message: message, data: error["data"])
finishPending(id: identifier, result: .failure(SoraError.rpcServerError(detail: detail)))
```

`RPCErrorDetail` の stored property は `code: Int` / `message: String` / `data: Any?` の 3 つで、前の 2 つは `Sendable` である。`Any?` だけが `Sendable` を妨げている。

`RPCErrorDetail` を `@unchecked Sendable` にして警告を消すことはできるが、`Any?` が不変であることをコンパイラが検証できないため、この方法は採らない。

`0109` は既存の `RPCMethodProtocol` / `RPCResponse` / `RPCErrorDetail` / `MediaChannel.rpc` を削除も変更もしないと定めており、新しい RPC API 側だけで deep-Sendable な error detail を用意する。したがって、既存 `RPCErrorDetail` の修正は本 issue が単独で扱う。

## 設計方針

- `RPCErrorDetail.data` の型を `Any?` から deep-Sendable な JSON value 型へ変更する。`JSONSerialization` が返す `Any` を `RPCErrorDetail` へ入れる経路をなくす。
- JSON value 型は `0102` が `Sora/JSONValue.swift` に置く `JSONValue` を公開型として再利用する。`0102` が internal のままとした場合は、本 issue で public 化する判断を `0102` と揃える。
- `Any?` を `@unchecked Sendable` で包む方法、および `SoraError.rpcServerError(detail:)` を削除する方法は採らない。前者は不変性を検証できず、後者は後方互換がない。
- `data` の型変更は後方互換がないため `CHANGES.md` に `[CHANGE]` として記載し、次期 major version で取り込む。`Milestone:` は指定しない。
- `0108` (Swift 6 language mode) と `0118` (warnings-as-errors) より先に完了させる。先に完了できない場合は、`SoraError` の警告を一時的に許容する条件を `0108` / `0118` に明記する。
- 実装コードとテストのコメントには issue 番号を書かない。理由そのもの (non-Sendable な `Any?` を運ばない等) を書く。

## 変更対象

- `Sora/RPC.swift`: `RPCErrorDetail.data` の型変更と `RPCChannel` の変換
- `Sora/JSONValue.swift`: `JSONValue` の公開 (`0102` の完了状況による)
- `SoraTests/RpcE2ETests.swift` / `SoraTests/E2ETestBase.swift`: `rpcServerError` 経路の検証
- `CHANGES.md`

## 前提となる issue

- `0123` (未完了): `SoraTests` の `requireSendable`。本 issue の型検査は `0123` が `SoraTests/SendableConformanceTests.swift` に新設する `requireSendable` を使う。`0123` の完了前に着手する場合は同じ helper を重複定義しないよう、先に `0123` の実装状況を確認する。
- `0102` (未完了): `Sora/JSONValue.swift` の `JSONValue`。完了前に着手する場合は、本 issue で `JSONValue` を追加し、`0102` と重複しないよう先に `0102` の実装状況を確認する。

### 本 issue の完了後に着手する issue

- `0108`: `Package.swift` を Swift 6 language mode へ移行する
- `0118`: E2E test target の concurrency 診断抑止を除去する

## テスト方針

モックやスタブは使用しない。

- 実 Sora に対してサーバーエラーを返す RPC を呼び、`SoraError.rpcServerError(detail:)` の `data` が変更前と同じ JSON 構造として読めることを確認する。
- `RPCErrorDetail` を `requireSendable` で表明し、actor / Task 境界へ渡せることをコンパイル時に確認する。
- `Sora/` 全体を `swiftc -typecheck -swift-version 6` で検査し、`SoraError` の conformance 警告が消え、新しい警告が増えていないことを確認する。
- 既存テストがすべて成功することを確認する。

## 完了条件

- `RPCErrorDetail` が `Sendable` に準拠し、`Swift 6` の型検査で conformance 警告が出ないこと。
- `data` の JSON 構造が変更前と等価であることをテストで確認していること。
- `@unchecked Sendable` を `RPCErrorDetail` へ付与していないこと。
- `CHANGES.md` の `## develop` に `[CHANGE]` として追記し、`data` の型変更が後方互換でないことを明記していること。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
