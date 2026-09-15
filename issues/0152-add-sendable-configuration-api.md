# 利用者が actor / Task 境界へ渡せる公開 Sendable 設定型を追加する

- Created: 2026-09-15
- Completed:
- Priority: Medium
- Branch: feature/add-sendable-configuration-api
- Polished:

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

`0102` は接続開始時にこれらを internal な `ConnectionConfigurationSnapshot` へ写し取るが、internal のため通常の consumer は `import Sora` から参照できない。`0107` の consumer fixture は `@testable` と `@preconcurrency` を禁止しており、internal 型を検証対象にできない。

## 設計方針

- 内部型である `ConnectionConfigurationSnapshot` をそのまま公開しない。内部都合の変更が公開 API の互換性を縛るためである。
- 公開設定型は deep Sendable な値だけで構成し、handler を含めない。event の購読は `0110` の Sendable event API が担う。
- `Sora.connect` に新しい overload を追加し、既存の `connect(configuration:webRTCConfiguration:handler:)` は維持する。
- 既存 `Configuration` からの変換経路を用意し、利用者が段階的に移行できるようにする。
- `0102` の完了を前提とする。`0102` が確定する snapshot のフィールド分類を再利用する。

## 前提となる issue

- `0102`: 内部 snapshot の型と変換を提供する。
- `0110`: handler を Sendable な event API として提供する。
- `0123`: 公開 value type への `Sendable` 準拠を提供する。
- `0107`: consumer fixture による strict concurrency 検証の基盤。

## 完了条件

- 公開 Sendable な設定型が追加され、利用者が actor / Task 境界で設定値を渡せること。
- 設定型が handler を含まず、deep Sendable であること。
- `0107` の consumer fixture で `SWIFT_STRICT_CONCURRENCY=complete` と warnings-as-errors により compile できること。
- 既存の `Configuration` と `Sora.connect` の公開 API が維持されていること。
- `CHANGES.md` に `[ADD]` として追記していること。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
