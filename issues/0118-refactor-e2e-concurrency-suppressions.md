# E2E テストの concurrency 診断抑止を除去する

- Created: 2026-08-27
- Completed:
- Branch: feature/refactor-e2e-concurrency-suppressions
- Polished:

## 目的

E2E テストが `@preconcurrency import Sora` と根拠のない `@unchecked Sendable` に依存する状態を解消し、Swift 6 の strict concurrency diagnostic をテストコードにも適用する。

診断を抑止せず、callback と test state の executor 境界をコードで保証する。

## 現状

`SoraTests/E2ETestBase.swift` と 6 つの E2E test ファイルは、合計 7 箇所で `@testable @preconcurrency import Sora` を使用している。

`E2ETestBase` は `@MainActor` だが、SDK callback は WebSocket、DataChannel、WebRTC の callback executor から到達する。各 test は一部を `DispatchQueue.main.async` へ送っているものの、`@preconcurrency` により non-Sendable capture と isolation の診断が抑止されている。

`SoraTests/DummyVideoCapturer.swift` は main RunLoop の `Timer` と可変状態を保持するが、class 全体を `@unchecked Sendable` にしている。lock と executor assertion は存在しない。

`@preconcurrency import Accelerate` は C API annotation の不足を局所的に補う別の境界であり、根拠を確認せず本 issue で撤去しない。

## 設計方針

- 7 箇所の `@testable @preconcurrency import Sora` を通常の `@testable import Sora` へ変更する。
- E2E test の mutable state は `E2ETestBase` の MainActor または明示的な同期 storage で所有する。
- SDK callback から MainActor state を更新するときは、値を immutable snapshot にしてから 1 つの明示的な hop を行う。
- expectation の fulfill と test state の更新順序を同じ actor 上で決定する。
- `DummyVideoCapturer` は main RunLoop owner として `@MainActor` に隔離し、`@unchecked Sendable` を削除する。
- E2E test が production API の concurrency defect を回避するために新しい unchecked box を追加しない。SDK 側の修正が必要なら別の production issue として扱う。

## テスト方針

モックやスタブは使用しない。

- 全 E2E test target を Swift 6、strict concurrency complete、warnings-as-errors で build する。
- 実 Sora 接続を使う既存 E2E test を実行する。
- `DummyVideoCapturer` の start / stop / Timer callback が MainActor 上で実行されることを確認する。
- callback の連続到着中に test cancellation と tearDown を実行し、MainActor 外の state access がないことを確認する。
- テストには、callback から MainActor へ移動する理由と snapshot の境界を日本語コメントで記載する。

## 完了条件

- `SoraTests` に `@preconcurrency import Sora` が残っていないこと。
- `DummyVideoCapturer` から `@unchecked Sendable` が除去されていること。
- E2E test の mutable state が MainActor または明示的な同期 storage に隔離されていること。
- strict concurrency と warnings-as-errors で全 test target が build できること。
- 既存 E2E test がすべて成功すること。
- `@preconcurrency import Accelerate` を残す場合は、局所利用の理由が日本語コメントで説明されていること。

## 解決方法
