# Logger の共有可変状態を同期する

- Created: 2026-08-27
- Completed:
- Branch: feature/refactor-logger-shared-state
- Polished:

## 目的

`Logger.shared`、ログレベル、group、出力 handler を複数スレッドから安全に設定・参照できるようにし、`Logger: @unchecked Sendable` と `nonisolated(unsafe)` な共有 storage への依存を除去する。

ログ出力中に設定変更や handler からの再入が発生しても、データ競合、deadlock、設定の部分更新が起きない構造にする。

## 現状

`Sora/Logger.swift` の `Logger` は class 全体が `@unchecked Sendable` で、`sharedStorage` は `nonisolated(unsafe) static var` として定義されている。

次の mutable state に同期がない。

- `Logger.shared` の差し替え
- `onOutputHandler`
- `groups`
- `level`

`Logger.fatal`、`error`、`warn`、`info`、`debug`、`trace` は、URLSession、WebRTC、camera、DataChannel、main thread など複数の executor から呼ばれる。

`output(log:)` は `groups` と `level` を読み、`onOutputHandler` を呼ぶ。同時に利用者が設定を変更した場合はデータ競合になる。

handler を同期 lock の内側で呼ぶ実装にすると、handler 内から Logger の設定変更や再度のログ出力を行った場合に deadlock または再帰的な状態破壊が起きる。

`Log.description` が利用する共有 `DateFormatter` も複数のログ出力から同時に参照されるため、Logger の出力経路と合わせて concurrency 契約を確定する必要がある。

open の `0026` は `WrapperVideoEncoderFactory` の singleton だけを対象とし、Logger は明示的にスコープ外としている。

## 設計方針

### state storage

- Logger の設定を保持する小さい internal storage を導入し、1 つの lock または serial executor で保護する。
- `shared`、`level`、`groups`、`onOutputHandler` の get / set を storage 経由にする。
- 1 回のログ出力では、level、groups、handler を同じ lock 区間で immutable snapshot として取得する。
- filtering、secret masking、文字列整形、handler 呼び出し、`print` は lock の外で行う。

### handler の再入

- handler を呼ぶ前に設定 snapshot を確定し、handler 内から Logger を再設定または再度呼び出しても deadlock しないようにする。
- handler の交換後に既に開始済みのログが旧 handler と新 handler のどちらへ届くかを snapshot 時点で決定し、挙動をコメントに記載する。
- handler が同じログを再出力した場合の無限再帰は利用者責任とするか、必要な防御方針を明示する。根拠なく thread-local cache を追加しない。

### shared と formatter

- 公開 `Logger.shared` の getter / setter は source compatibility を維持する。
- `sharedStorage` の `nonisolated(unsafe)` を除去する。
- `DateFormatter` を共有する場合は同じ出力同期の下で利用する。可能であれば immutable / value-oriented な formatter へ置き換える。
- class 全体の `@unchecked Sendable` を残す場合は、全 mutable state が storage に閉じていることを型の直前に日本語コメントで説明する。

## スコープ外

- `Sora.shared`、`DeviceInfo.current`、WebRTC callback logger の lifecycle は別 issue とする。
- ログ API の廃止やログ形式の変更は行わない。
- ログ group の追加・削除は行わない。
- secret masking の仕様変更は行わない。

## テスト方針

モックやスタブは使用しない。

- 実 `Logger` を複数の `DispatchQueue` と Task から同時に呼び出し、level、groups、handler を並行して変更する。
- 実 handler 内から Logger の level / groups を変更し、再度ログを出力して deadlock しないことを確認する。
- 設定 snapshot の取得前後で handler を交換し、各ログが 1 つの handler にだけ通知されることを確認する。
- secret masking と出力 format が並行出力後も既存仕様と一致することを確認する。
- Thread Sanitizer を有効にして競合を検査する。
- 大量ログで lock を保持したまま handler や `print` を呼んでいないことを確認する。
- テストには、handler を lock 外で呼ぶ理由と snapshot の境界を日本語コメントで明記する。

## 完了条件

- `shared`、`level`、`groups`、`onOutputHandler` の全読み書きが同じ同期方針で保護されていること。
- 1 回のログ出力が整合した設定 snapshot を使用すること。
- filtering、masking、formatting、handler、`print` を設定 lock の外で実行すること。
- handler 内から Logger を再設定・再呼び出ししても deadlock しないこと。
- `sharedStorage` から `nonisolated(unsafe)` が除去されていること。
- `Logger: @unchecked Sendable` を残す場合は、安全性の根拠が mutable property 単位で成立していること。
- 既存のログレベル、group、secret masking、出力形式が維持されること。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
