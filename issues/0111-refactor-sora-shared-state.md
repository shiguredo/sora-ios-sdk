# Sora の共有状態と WebRTC logger lifecycle を同期する

- Created: 2026-08-27
- Completed:
- Branch: feature/refactor-sora-shared-state
- Polished:

## 目的

`Sora` の handler、SDK 初期化・終了、WebRTC callback logger の lifecycle を同期し、`Sora: @unchecked Sendable` と `nonisolated(unsafe)` な static state に依存しない構造へ移行する。

複数の `Sora` instance と `Sora.shared` が並行利用されても、handler のデータ競合、logger の start / stop 競合、SDK cleanup 中の再利用が起きないことを保証する。

## 現状

`Sora/Sora.swift` の `Sora` は class 全体が `@unchecked Sendable` である。

`mediaChannels` の配列は `mediaChannelLock` で保護され、add / remove callback も lock 外で呼ばれている。一方、次の状態は同じ同期方針に含まれていない。

- `SoraHandlers` の mutable closure property
- `audioSessionDelegateAdapter` からの handler 呼び出し
- static な SDK initialize / finish lifecycle
- `webRTCCallbackLogger`
- `webRTCLoggingDateFormatter`

`SoraHandlers` は利用者が任意の executor から property を変更できる。add、remove、connect、disconnect、audio route callback は別 executor から handler を読み出すため、Optional closure 自体の読み書きが競合する。

`webRTCCallbackLogger` は `nonisolated(unsafe) static var` である。`setWebRTCLogLevel(_:)` は severity を変更し、stop、start の順で logger を再設定するが、並行呼び出しに対する排他と generation がない。

`Sora.finish()` は global な WebRTC cleanup を実行するが、Sora instance または MediaChannel が存続・接続中かを管理しない。finish と新しい initializer / connect が競合した場合の契約もない。

`Logger.shared` 自体の同期は `0106` で扱うため、本 issue では `Sora` が所有する state と WebRTC callback logger だけを対象とする。

## 設計方針

### Sora instance state

- mediaChannels、handler snapshot、audio session delegate registration を扱う instance state owner を導入する。
- `SoraHandlers` の既存 property は source compatibility を維持し、get / set を同期 storage 経由にする。
- callback 呼び出し時は handler を lock 下で snapshot 化し、実行は lock の外で行う。
- handler の差し替えと callback が競合した場合、snapshot 取得時点の handler を 1 回だけ呼ぶ契約にする。
- `0110` の Sendable event API 導入後も、legacy handler は同じ内部 event から compatibility adapter として配送する。

### SDK lifecycle

- initialize、active instance / connection、finish の状態を process-wide lifecycle owner で管理する。
- initialize は厳密に 1 回行い、複数 instance の生成で重複実行しない。
- `finish()` の呼び出し中または完了後に instance / connection を利用した場合の挙動を明示する。
- active connection がある状態で finish を許可するか、明示的な error / precondition とするかを決める。理由なく cleanup を並行実行しない。
- 既存 `public static func finish()` のシグネチャを変更しない範囲で安全にできない場合は、新しい終了 API を追加して legacy API を compatibility wrapper とする方針を別途判断する。

### WebRTC callback logger

- logger instance、severity、running state、generation を process-wide logger owner が保持する。
- severity 更新、stop、start を同じ排他領域で順序付ける。
- logger callback は設定時の generation を持ち、古い callback を無視する。
- callback 内の日時整形と `print` は state lock の外で行う。
- `webRTCCallbackLogger` の `nonisolated(unsafe)` を除去する。

### Sendable

- `Sora` 全体の `@unchecked Sendable` を除去できるよう、mutable state を owner / synchronized storage に閉じ込める。
- vendor object のために unchecked adapter が必要な場合は、小さい internal final class に限定し、thread affinity を日本語コメントで説明する。

## スコープ外

- `Logger.shared` の state は `0106` で扱う。
- `ConnectionTask` と接続状態は `0092` / `0100` で扱う。
- 新しい Sendable event API は `0110` で扱う。
- raw `RTCAudioSession` を公開 event から除去する作業は `0110` と `0070` の方針に合わせる。
- 音声 unit の機能仕様は変更しない。

## テスト方針

モックやスタブは使用しない。

- 複数の実 `Sora` instance と `Sora.shared` を並行して生成・破棄する。
- handler の設定変更と add、remove、connect、disconnect、audio route event を競合させる。
- handler 内から handler を差し替え、connect / disconnect を呼んでも deadlock しないことを確認する。
- `setWebRTCLogLevel` を複数 Task から反復し、logger callback が重複登録されないことを確認する。
- 実 WebRTC log を出力し、古い generation の callback が停止後に出力しないことを確認する。
- active connection と `finish()` の組み合わせを、決定した lifecycle 契約に従って実機で検証する。
- Thread Sanitizer を補助的に有効化する。
- テストには、handler snapshot と logger generation の境界を日本語コメントで明記する。

## 完了条件

- `SoraHandlers` の全 property の読み書きが同じ同期方針で保護されていること。
- handler を state lock の外で呼び、再入しても deadlock しないこと。
- SDK initialize / finish の process-wide lifecycle が明示的に管理されること。
- active connection と finish の契約が API documentation に記載されていること。
- WebRTC callback logger の severity、start、stop、generation が同じ owner で管理されること。
- `webRTCCallbackLogger` から `nonisolated(unsafe)` が除去されていること。
- `Sora: @unchecked Sendable` が不要になるか、安全性を説明できる小さい adapter だけに unchecked が限定されていること。
- 複数 `Sora` instance の既存挙動と public API の source compatibility が維持されること。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
