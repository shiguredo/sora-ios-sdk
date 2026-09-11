# SoraError 型に定義するエラーの粒度の方針を検討する

- Created: 2026-09-11
- Completed: {YYYY-MM-DD}
- Branch: feature/investigate-sora-error-granularity
- Polished: {YYYY-MM-DD}

## 目的

`SoraError` に定義するエラーの粒度（`SignalingChannel` 全体のエラーを 1 つにまとめるか、内部の特定事象ごとに定義するかなど）の基準が統一されていない。方針を決めて `SoraError.swift` の冒頭コメントに記載し、今後のエラー追加時の判断基準とする。

## 現状

`SoraError` には粒度の異なるエラーが混在している。

- チャネルや機能の単位でまとめたエラー: `webSocketError` / `signalingChannelError` / `peerChannelError` / `mediaChannelError` / `cameraError` / `messagingError`
- 特定の事象ごとのエラー: `connectionCancelled` / `connectionTimeout` / `invalidSignalingMessage` / `unknownSignalingMessageType` / `webSocketClosed` / `dataChannelClosed` / `rpcUnavailable` / `rpcEncodingError` / `rpcDecodingError` / `rpcDataChannelClosed` / `rpcTimeout` / `rpcServerError`
- 汎用の理由付きエラー: `configurationError` / `connectionBusy`

どの粒度で定義するかの基準がなく、エラーを追加するたびに判断がぶれる。

## 設計方針

- 粒度の基準を整理し、`SoraError.swift` の冒頭コメントに方針を記載する
- 利用者がエラー種別ごとに分岐して処理できることを優先するか、定義数を抑えて網羅性を優先するかの観点で比較検討する

## pending にした理由

方針の検討が必要だが緊急ではなく、他の優先度の高い作業を先に進めるため pending とする。方針が決まったら `SoraError.swift` の冒頭コメントに記載して closed にする。

## 解決方法

## Pending 解除条件

- エラーの粒度の方針を決定し、`SoraError.swift` の冒頭コメントに記載する。
- 方針に沿って既存の `SoraError` の見直しが必要か判断する。
