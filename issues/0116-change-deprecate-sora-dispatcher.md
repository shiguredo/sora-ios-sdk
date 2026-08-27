# SoraDispatcher を非推奨にする

- Created: 2026-08-27
- Completed:
- Branch: feature/change-deprecate-sora-dispatcher
- Polished:

## 目的

libwebrtc の内部 queue identity を公開する `SoraDispatcher` を非推奨にし、利用者が generic closure を WebRTC queue へ投入する API から目的別 SDK API へ移行できるようにする。

本 issue は非推奨化と SDK 内部利用の解消を扱い、公開型の削除は `0117` へ分離する。

## 現状

`Sora/SoraDispatcher.swift` は public enum として camera / audio queue を公開し、`RTCDispatcher.dispatchAsync` を呼ぶ `async(on:block:)` を提供する。

closure は非 `@Sendable` であり、利用者は任意の mutable reference を libwebrtc queue へ移送できる。また `RTCDispatcherQueueType` は libwebrtc の内部実装詳細であり、SDK の将来の thread model を公開契約として固定する。

production code では `Sora/VideoMute.swift` と `Sora/MediaChannel.swift` がカメラ操作のために利用している。これらは generic dispatch ではなく camera owner の command として表現すべき処理である。

## 前提となる issue

- `0103`: カメラ状態と操作を camera owner へ集約する。

audio queue を使用する production code が追加された場合は、その処理の owner / adapter も先に用意する。

## 設計方針

- `VideoMute` と `MediaChannel` から `SoraDispatcher` の直接利用を除去する。
- WebRTC / camera / audio 操作は目的別の internal owner / command を経由する。
- generic な public dispatch API を、新しい internal generic closure API としてそのまま複製しない。
- `SoraDispatcher` と `async(on:block:)` を deprecated にする。
- deprecation message では、目的別のカメラ・音声 API を利用するよう案内する。
- 既存 method の closure 型へ直接 `@Sendable` を追加しない。既存利用者の capture を compile error にするためである。
- 非推奨期間中は legacy API の既存 queue 配送挙動を維持する。
- `0070` の WebRTC C API 移行で同じ dispatcher abstraction を二重に導入しない。

## スコープ外

- 公開 `SoraDispatcher` の削除は `0117` で扱う。
- camera owner の実装は `0103` で扱う。
- AudioSession event は `0035` で扱う。
- WebRTC C API への移行は `0070` で扱う。

## テスト方針

モックやスタブは使用しない。

- 実カメラで hard mute、unmute、start、stop、restart が camera owner 経由で動作することを確認する。
- production code に `SoraDispatcher` の参照が残っていないことを確認する。
- `0107` の legacy consumer fixture から `SoraDispatcher` を呼び、既存コードが compile できることを確認する。
- deprecated warning に削除予定と目的別 API への移行案内が表示されることを確認する。
- API baseline で deprecation 以外の意図しない break がないことを確認する。
- テストには、generic dispatch ではなく目的別 command を利用する理由を日本語コメントで明記する。

## 完了条件

- production code が `SoraDispatcher` を利用していないこと。
- camera / audio 操作が目的別の internal owner / command を経由すること。
- `SoraDispatcher` と `async(on:block:)` が deprecated であること。
- 既存 method の closure 型へ直接 `@Sendable` を追加していないこと。
- legacy consumer fixture が引き続き compile できること。
- `0070` と重複する dispatcher abstraction を追加していないこと。
- API baseline に意図しない変更がないこと。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
