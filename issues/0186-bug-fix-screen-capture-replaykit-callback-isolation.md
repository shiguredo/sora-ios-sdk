# 画面キャプチャの ReplayKit コールバックが MainActor 隔離を継承し、配信開始時に実行時隔離チェックでクラッシュする問題を修正する

- Created: 2026-10-09
- Completed: {YYYY-MM-DD}
- Branch: feature/fix-screen-capture-replaykit-callback-isolation
- Polished: 2026-10-09
- Reporter: @t-miya

## 目的

画面キャプチャを開始した直後にクラッシュする問題を修正する。sora-ios-sdk-samples の ScreenCast サンプルで配信を開始すると再現し、画面キャプチャが利用できない。

## 現状

`Sora/ScreenCapture.swift` の `ScreenCaptureController.startRecorderCaptureIfIdle()` は `RPScreenRecorder.startCapture(handler:completionHandler:)` を `Task { @MainActor in ... }` の中で呼び、`handler:` へクロージャリテラルを渡している。ReplayKit の `handler:` 引数は `@Sendable` ではないため、このクロージャは外側の `Task { @MainActor in ... }` の MainActor 隔離を継承する。

ReplayKit はこの handler を自身のキュー (`com.replaykit.capture.AudioSampleQueue` など) から呼ぶため、Swift 6 言語モードの動的隔離チェックが `_dispatch_assert_queue_fail` でプロセスを終了させる。handler はサンプルバッファごとに呼ばれるので、画面キャプチャを開始した直後の最初のバッファでクラッシュする。

`ScreenCaptureController.stopRecorderCapture()` の `RPScreenRecorder.stopCapture` に渡す完了クロージャも同じ構造で、同じ隔離を継承する。

- クラッシュの証跡: スレッドは `com.replaykit.capture.AudioSampleQueue`、停止関数は `_dispatch_assert_queue_fail`、メッセージは `BUG IN CLIENT OF LIBDISPATCH: Assertion failed: Block was expected to execute on queue [...]`。
- 型検査での確認: `Task { @MainActor in recorder.startCapture { ... } }` の中の `handler` クロージャからは MainActor 隔離の関数を同期呼び出しでき、同位置の `completionHandler` クロージャからは呼び出せない (警告になる)。`handler` に `@Sendable` を付けると警告に変わる。
- 実行時隔離チェックは Swift 6 言語モードで compile した場合だけ生成される。SwiftPM で取り込む consumer は `0108` が `swiftLanguageModes: [.v6]` を package へ導入するまで SDK を Swift 5 言語モードで compile していたため、それ以前は隔離違反が表面化していなかった (repo の `xcodebuild` は `0108` 以前から `SWIFT_VERSION=6` を渡しているが、この override は consumer へ伝播しない)。
- `SoraTests` に画面キャプチャを実行するテストは無く (`ScreenCaptureFrameGenerationTests` は `enqueueOwnedFrame` と `performSend(ownedFrame:)` を直接呼び、ReplayKit のコールバック経路を通らない)、CI では検出できない。
- 再現手順: 実機で `MediaChannel.startScreenCapture` を実行する。sora-ios-sdk-samples の ScreenCast サンプルで配信を開始すると再現する。

## 設計方針

ReplayKit のコールバックを非隔離にする。`RPScreenRecorder.startCapture` の `handler:` と `RPScreenRecorder.stopCapture` の完了クロージャへ `@Sendable` を付ける。`startCapture` の `completionHandler:` は ReplayKit 側で `@Sendable` として import されるため現状すでに非隔離だが、3 つのコールバックすべてで隔離の契約がコード上に現れるよう、ここにも `@Sendable` を明示する (明示しても診断は変わらない)。

MainActor 上で行う必要がある処理は、既存どおりクロージャの中の `Task { @MainActor in ... }` で行う。`@Sendable` はクロージャの隔離を外すだけで、`ScreenCaptureController` は `@unchecked Sendable` のため捕捉はそのまま許される。

あわせて `Sora/ScreenCapture.swift` の `ScreenCaptureController` の doc コメントを更新する。`@unchecked Sendable` の根拠の最終項は「ReplayKit callback と recorder の完了 callback は `Task { @MainActor in ... }` から呼ばれ」と書いており、この変更後は `@Sendable` を付けたクロージャが ReplayKit のキューから直接呼ばれるため、記述を実装と一致させる (状態の読み書きが `lock` の区間内である点は変わらない)。

同種の「MainActor 隔離を継承したクロージャを非 `@Sendable` な外部コールバックへ渡している」箇所が他に無いことを確認する。`Sora/` で `Task { @MainActor in ... }` を持つのは `Sora/ScreenCapture.swift` のみである。

## 完了条件

- 実機で `MediaChannel.startScreenCapture` を実行してもクラッシュしない。
- ReplayKit のコールバックが MainActor 隔離を継承していないことを型検査または実行で確認できる。
- `Sora/` に同種の隔離漏れが残っていないことを確認できる。

## 解決方法
