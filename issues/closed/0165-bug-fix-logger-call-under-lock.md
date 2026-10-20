# SDK 内部の排他区間を保持したまま Logger を呼ぶと利用者の出力 handler が deadlock する問題を修正する

- Created: 2026-09-18
- Completed: 2026-09-28
- Priority: Medium
- Branch: feature/fix-logger-call-under-lock
- Polished: 2026-09-18

## 目的

利用者が `Logger.shared.onOutputHandler` を設定している場合に、SDK 内部の排他区間 (NSLock と serial queue の `sync`) を保持したまま Logger を呼ぶ経路で deadlock が起きる問題を解消する。

Logger の出力 handler は logging を呼び出した executor 上で同期に呼ばれる。SDK が排他区間を保持したまま Logger を呼ぶと、handler から同じ lock (または同じ serial queue) を使う SDK の API を呼んだときに非再帰 lock の再取得、または `queue.sync` の再入で停止する。

`0106` は Logger 自身の同期を扱う。本 issue はその対になる call site 側の問題を扱う。

## 現状

- `Sora.add(mediaChannel:)` / `Sora.remove(mediaChannel:)` は `mediaChannelLock` を保持したまま `Logger.debug` を呼ぶ。`Sora.mediaChannels` は同じ `mediaChannelLock` を取る。`mediaChannelLock` は `Sora` instance ごとの `NSLock` である。
- `ConnectionTask.cancel()` は `ConnectionTask.stateLock` を保持したまま `Logger.debug` を呼ぶ。`ConnectionTask.state` は同じ `stateLock` を取る。`cancel()` は public で、`Sora.connect` の戻り値から利用者が呼べる。
- `ConnectionTask.tryComplete()` は `stateLock` を保持したまま `Logger.debug` を呼ぶ。ログは `connecting` から `completed` へ遷移したときだけ出る (`tryComplete()` は遷移の有無を返し、`complete()` は戻り値を捨てている)。
- `ConnectionTimer.run(timeout:handler:)` と `ConnectionTimer.stop()` は `ConnectionTimer.stateLock` を保持したまま `Logger.debug` を呼ぶ。Timer callback 内の 3 つのログ (`validate timeout` / `found timeout` / `all OK`) は `stateLock` を解放済みの箇所で呼ばれている。
- `MediaChannel` は `connectionLifecycleLock` を保持したまま `ConnectionTimer.run` を呼ぶ。`MediaChannel.finishConnect` と `MediaChannel.beginDisconnect` は同じ lock を保持したまま `ConnectionTask.tryComplete()` / `complete()` を呼び、`MediaChannel.finishDisconnect` は lock を解放してから 3 箇所 (`disconnectFinished` 済みと `state` が `.disconnecting` でない 2 箇所の early return、通常経路の 1 箇所) で `complete()` を呼ぶ。`MediaChannel.disconnect(error:)` は同じ `connectionLifecycleLock` を取る。
- `MediaChannel.state` は `didSet` で `Logger.trace` を呼ぶ。`state` への代入のうち `connectionLifecycleLock` を保持して行われるものがある (`connecting` / `connected` / `disconnecting` / `disconnected` への 5 箇所)。
- `AudioDeviceModuleWrapper.setAudioHardMute(_:)` は serial queue の `queue.sync` 区間内で `Logger.debug` / `Logger.error` を呼ぶ。`MediaChannel.setAudioHardMute(_:)` は public で、接続状態と `audioEnabled` と `isSender` を確認してから wrapper を呼ぶ (この関数自身は Logger を呼ばない)。
- `Sora/MediaStream.swift` と `Sora/StreamFrameOwner.swift` には、同じ理由で「lock 保持中に Logger を呼ばない」ことを説明するコメントがあり、そこでは既に回避されている。

## 再現手順

`@testable import Sora` から対象の API を直接呼べば再現でき、実 Sora サーバーへの接続は不要である。

1. `_ = Sora.shared` を評価して SDK を初期化しておく (`Sora.isInitialized` の初期化子経由で `Logger.debug` が呼ばれるため、handler から最初に `Sora.shared` を読むと `Sora.shared` の遅延初期化が再帰して停止する)。
2. `Logger.shared.level = .debug` にする。
3. `Logger.shared.onOutputHandler = { _ in _ = Sora.shared.mediaChannels }` にする。
4. `Sora.shared.add(mediaChannel:)` を呼ぶ。`mediaChannelLock` は instance ごとなので、handler が読む instance と `add` する instance を必ずそろえる。

`Sora.shared.add(mediaChannel:)` が `mediaChannelLock` を保持したまま `Logger.debug` を呼び、handler の `Sora.shared.mediaChannels` が同じ lock を再取得するため停止する (`MediaChannel` は `Sora.connect` の `onPrepared` で追加される)。

`Logger.shared.onOutputHandler = { _ in _ = task.state }` としてから接続中の `ConnectionTask.cancel()` を呼ぶ経路、`MediaChannel.disconnect(error:)` を handler から呼ぶ経路、`MediaChannel.state` の遷移ログ (`level = .trace`) から同じ handler を呼ぶ経路でも同様に停止する。

## 前提となる issue

- `0106`: Logger の共有可変状態の同期。Logger が handler 実行中に自身の lock を保持しないことと、`Logger.shared.level` の書き込みが差し替え前の instance に適用され得ることを前提とする (再現手順は `Logger.shared` を差し替えないため、`0106` の完了後も再現する)。
- `0111`: `Sora` の instance state の owner 化。`Sora.add(mediaChannel:)` / `remove(mediaChannel:)` / `mediaChannels` の構造を変えるため、どちらかを先行させもう一方を rebase する。

## 設計方針

- 排他区間の外で Logger を呼ぶ。ログの内容 (`level` / `type` / `message`) と、同一スレッド・同一経路での出力順序は変えない。スレッドをまたぐ順序は保証しない (状態遷移の直列化は維持し、ログの順序は保証対象にしない)。
- 出力 handler は利用者の callback であるため、SDK 内部の lock を保持したまま呼ばない。`Sora` の `handlers` callback と同じ規則とする。
- ログの出力元を次の表のとおりに固定する。

| 経路 | ログ (`level` / `type` / `message`) | 出す条件 | 出す位置 |
| --- | --- | --- | --- |
| `Sora.add(mediaChannel:)` / `remove(mediaChannel:)` | `.debug` / `.sora` / `add media channel` / `remove media channel` | 追加・削除が成立したとき (現行と同じ) | `mediaChannelLock` 解放後、`handlers` callback より前 |
| `ConnectionTask.cancel()` | `.debug` / `.mediaChannel` / `connection task cancelled` | `cancelRequested` へ遷移したとき (現行と同じ) | `stateLock` 解放後 |
| `ConnectionTask.tryComplete()` / `complete()` | `.debug` / `.mediaChannel` / `connection task completed` | `completed` へ遷移したとき (現行と同じ。遷移するのは接続試行中だけ) | 呼び出し元が自らの lock を解放した後 (busy 経路は handler の後) |
| `ConnectionTimer.run(timeout:handler:)` | `.debug` / `.connectionTimer` / `run (timeout: N seconds)` | 呼ばれたとき (現行と同じ)。`N` は lock 内で確定した有効値 | `MediaChannel.basicConnect` が `connectionLifecycleLock` 解放後 |
| `ConnectionTimer.stop()` | `.debug` / `.connectionTimer` / `stop` | 呼ばれたとき (現行と同じ) | `stop()` の中で `stateLock` 解放後 |
| `MediaChannel.state` | `.trace` / `.mediaChannel` / `changed state from A to B` | 代入が実行されたとき (現行と同じ)。`A` / `B` は lock 内で確定 | Lock 解放後 |
| `AudioDeviceModuleWrapper.setAudioHardMute(_:)` | 成功時 `.debug` / 失敗時 `.error`、type は `.mediaChannel` / `setAudioHardMute via RTCAudioDeviceModule mute=...` (失敗時は末尾に ` failed`) | 現行と同じ | `queue.sync` の外 |

- 経路ごとの実装を次に固定する。
  - `ConnectionTask.tryComplete()` は Logger 呼び出しを削除する (戻り値と `@discardableResult` は現行のまま)。`complete()` は遷移の有無を返す `@discardableResult -> Bool` にする (呼び出し元が戻り値を捨てる経路があるため)。`connection task completed` を出す呼び出し元は `Sora.connect` の設定エラー経路 (`Sora.swift`)、`MediaChannel.connect` の busy 経路と `onDisconnect` で `self` が解放済みの経路、`MediaChannel.finishConnect`、`MediaChannel.beginDisconnect`、`MediaChannel.finishDisconnect` (3 箇所の `complete()` 呼び出し) である。現行の「遷移した場合だけ 1 回」を保つため、戻り値を使わない経路でも `let completed = task.complete()` の形で受け取る。
  - `MediaChannel` の完了ログと state 遷移ログの相対順序は現行のままとする (`finishConnect` と `beginDisconnect` は完了ログ → 遷移ログ、`finishDisconnect` は遷移ログ → 完了ログ)。両方を lock 解放後に出す場合も、この順で出す。
  - `ConnectionTimer.run(timeout:handler:)` は Logger 呼び出しを削除し、その呼び出しで有効になった timeout (lock 内で確定した `self.timeout`) を返す (`@discardableResult` を付ける)。呼び出し元は lock を解放した後に `run (timeout: N seconds)` を出す (現行は `run` の冒頭で出している)。`MediaChannel.basicConnect` の guard は `run` を呼ぶ前にあるため、呼び出し元は `run` を呼んだ場合に無条件で出す。
  - `ConnectionTimer.stop()` は Logger 呼び出しを `stateLock` の外へ移す。呼び出し元は `MediaChannel` の 3 箇所と Timer callback の 1 箇所で、いずれも `connectionLifecycleLock` を保持していない。
  - Timer callback 内の 3 つのログは `stateLock` を解放済みの箇所にあるため変更しない。
  - `MediaChannel.state` は `didSet` から Logger 呼び出しを削除し、`connectionLifecycleLock` を保持して遷移する 5 箇所が lock を解放した後に遷移ログを出す。`A` / `B` は lock 内でローカルへ取り出し、unlock 後に `state` を読み直さない。`finishDisconnect` は 1 つの lock 区間で最大 2 回遷移し unlock する exit が複数あるため、遷移 (`A` / `B`) を lock 内でローカルへ蓄積し、unlock する各 exit (`prepare` 経路で return する箇所を含む) で unlock 直後に出す。
  - `AudioDeviceModuleWrapper.setAudioHardMute(_:)` は vendor object の操作だけを `queue.sync` で行い、戻り値を受け取ってから lock の外でログを出す。
- Logger の同期方針は `0106` の結果を前提とし、本 issue では変更しない。

## 変更対象

- `Sora/Sora.swift`: `add(mediaChannel:)` / `remove(mediaChannel:)` と `ConnectionTask.cancel()` の Logger 呼び出しを排他区間の外へ出し、`ConnectionTask.tryComplete()` / `complete()` の Logger 呼び出しを削除して遷移の有無を返すようにし、`Sora.connect` の設定エラー経路で lock の外から完了ログを出す
- `Sora/ConnectionTimer.swift`: `run(timeout:handler:)` の Logger 呼び出しを削除して有効な timeout を返すようにし、`stop()` の Logger 呼び出しを `stateLock` の外へ出す
- `Sora/MediaChannel.swift`: `basicConnect` で `connectionLifecycleLock` を解放した後にタイマー開始ログを出し、`connect` / `finishConnect` / `beginDisconnect` / `finishDisconnect` で lock の外から完了ログを出し、`state` の `didSet` から Logger 呼び出しを削除して lock 解放後に遷移ログを出す
- `Sora/AudioDeviceModuleWrapper.swift`: `setAudioHardMute(_:)` の Logger 呼び出しを `queue.sync` の外へ出す
- `CHANGES.md`: `## develop` の主リストの `[FIX]` の並びの末尾に `- [FIX] SDK 内部の排他区間を保持したまま Logger を呼ぶと利用者の出力 handler が deadlock する問題を修正する` を担当者行付きで追記する (担当者行は `shiguredo-changelog` の書式に従い `  - @t-miya` とする。`### misc` ではなく主リストに置くのは、利用者が観測できる deadlock の修正であるため)
- `SoraTests/LoggerCallUnderLockTests.swift` (新規): 下記の回帰テスト
- `SoraTests/AudioDeviceModuleWrapperTests.swift`: `AudioDeviceModuleWrapper` 経路の回帰テストを追加

## テスト方針

モックやスタブは使用しない。`Logger.shared` に実 handler を設定し、handler から同じ lock / serial queue を使う SDK の API を呼ぶ経路を作る。記録は lock で保護した実 collector (`SoraTests/CameraStateOwnerTests.swift` の collector と同じ形) で行う。`XCTestExpectation` の timeout は 5 秒とする。`Logger.shared` と `Sora.shared` はプロセス全体の共有状態のため、これらのテストは直列実行を前提とする。

- 最初に `_ = Sora.shared` を評価してから handler を設定する。
- handler は対象の `Log.message` でのみ再入し、再入は 1 段に制限する。1 段制限のフラグはテストごと (インスタンス変数またはテストローカルな collector) に持つ (2 回目以降は何もしない)。1 段制限が無いと、修正後は再入が無限に続く。handler が対象ログを受け取ったことを記録で確認する。
- **deadlock を起こす入口の SDK 呼び出しはすべて専用 queue から実行し、テストスレッドは expectation を待つだけにする**。テストスレッドで同期実行すると、退行時に `wait(for:timeout:)` に到達する前に停止してテスト実行全体がハングする (CI は `timeout-minutes: 45` まで気付けない)。NSLock の再取得はハングし、serial queue の `sync` の再入は libdispatch の abort で停止する。handler は再入呼び出しが戻ってから expectation を fulfill し、timeout した場合は `XCTFail` のみ記録して即 return する (停止した lock を取る SDK の accessor をテストスレッドから読まず、観測は collector に記録済みの値で行う)。
- 対象ログの `LogType` を通す `groups` を設定する。`ConnectionTimer` のログは `.connectionTimer` で既定の `groups` に含まれないため、その経路では `groups` に `.connectionTimer` を追加する。`level` は既定が `.info` で、`SoraTests/E2ETestBase` は `.warn` を設定するため、`.debug` のログは各テストで `level = .debug` を明示し、`MediaChannel.state` の遷移ログは `level = .trace` を明示する。
- 到達確認: 各経路で「対象ログを handler が受け取ったこと」を expectation で確認する。到達しなかった場合は、その経路の検証が成立していないため `XCTFail` する (handler が呼ばれないまま成功するテストにしない)。
- `Sora.add(mediaChannel:)`: handler 内から `add` した instance の `mediaChannels` を読む (handler が読む instance と `add` する instance をそろえる。`Sora.shared` を使う必要はない)。`add` を別 queue から実行し、deadlock しないことを確認する。
- `ConnectionTask.cancel()`: handler 内から対象の `ConnectionTask.state` を読む。接続中の task に対して `cancel()` を別 queue から呼び、deadlock しないことを確認する。
- `MediaChannel.disconnect(error:)`: `level = .debug` と既定の `groups` で、接続試行中 (`state == .connecting`) に handler 内から同じ `MediaChannel.disconnect(error:)` を呼ぶ (`connection task completed` が出るのは `connecting` からの遷移だけである)。完了ログの経路で deadlock しないことを確認する。
- `finishDisconnect` の遷移ログ: `MediaChannel.connect` の直後に `ConnectionTask.cancel()` を呼び、`prepare` 経路で return する場合を含めて遷移ログが出ることとその順序を確認する。
- `MediaChannel` のタイマー開始: `groups` に `.connectionTimer` を設定し、`MediaChannel.connect` から `basicConnect` の `ConnectionTimer.run` に到達したことを対象ログの受信で確認したうえで、handler 内から `MediaChannel.disconnect(error:)` を呼び、deadlock しないことを確認する。
- `MediaChannel.state` の遷移: `level = .trace` とし、遷移ログを受信した handler から同じ `MediaChannel.disconnect(error:)` を呼ぶ経路で deadlock しないことを確認する。
- `ConnectionTimer.run` / `stop` の経路: `@testable import Sora` で `ConnectionTimer` を直接使い、`groups` に `.connectionTimer` を追加したうえで、`run` の後に `stop()` を呼び、handler 内から `ConnectionTimer.isRunning` を読む経路で deadlock しないことを確認する (`run` のログは `MediaChannel.basicConnect` が出すため、直接使うテストでは `stop()` のログを契機にする)。`ConnectionTimer.stateLock` と `ConnectionTask.stateLock` は private のままでよく、テストは `ConnectionTask.state` / `ConnectionTimer.isRunning` / `MediaChannel.isConnectionTimerRunning` などの accessor を使う。
- `AudioDeviceModuleWrapper.setAudioHardMute(_:)`: 既存の `SoraTests/AudioDeviceModuleWrapperTests.swift` と同じく factory に渡していない実 `RTCAudioDeviceModule` を渡した wrapper を直接使う。この ADM は `resumeRecording` / `pauseRecording` が失敗を返し、`setAudioHardMute via RTCAudioDeviceModule mute=false failed` が `Logger.error` で出る。handler の対象をこのメッセージに限定し、handler 内から同じ wrapper の `setAudioHardMute(_:)` を 1 段だけ呼んで deadlock しないことを確認する。
- ログの内容 (`level` / `type` / `message`) と同一スレッド・同一経路での出力順序が変わらないことを、実 handler が受け取る `Log` で確認する。順序は経路ごとの期待 `Log.message` の並びで確認する (`finishConnect` と `beginDisconnect` は完了ログ → 遷移ログ、`finishDisconnect` は遷移ログ → 完了ログ)。
- 後始末: `tearDown` は `Logger.shared.onOutputHandler` を復元し、その後に `add` した instance から MediaChannel を `remove` し、最後に `Logger.shared` の `level` / `groups` と対象 instance の状態を検証する (`remove` 自身が `Logger.debug` を出すため、handler を戻す前に `remove` すると handler が再度走る)。deadlock で停止した経路がある場合は、SDK の状態の後始末 (`remove` / 切断完了待ち) は行わず `Logger.shared` の設定だけを復元する (停止した lock を待たない)。
- Thread Sanitizer は `0119` に従う (完了条件には含めない)。

## 完了条件

- 設計方針の表に列挙した経路で、SDK 内部の lock または serial queue の `sync` 区間を保持したまま Logger を呼んでいないこと。
- 利用者の `onOutputHandler` から `mediaChannels` / `ConnectionTask.state` / `MediaChannel.disconnect(error:)` / `ConnectionTimer.isRunning` を呼んでも deadlock しないこと (テストで検証する)。
- `AudioDeviceModuleWrapper.setAudioHardMute(_:)` の経路で、handler から同じ API を 1 段呼んでも deadlock しないこと (テストで検証する)。
- ログの `level` / `type` / `message` と同一スレッド・同一経路での出力順序が現行と同じであること。
- `MediaChannel` のタイマー開始と接続試行完了の直列化が維持されていること。
- `CHANGES.md` の `## develop` の主リストの `[FIX]` の並びに、担当者行を含む `[FIX]` が追記されていること。
- 追加したテストと既存テストが失敗 0 で終わること。

### 検証手段

- `grep -nE "Logger\.(fatal|error|warn|info|debug|trace)\(" Sora/Sora.swift Sora/ConnectionTimer.swift Sora/MediaChannel.swift Sora/AudioDeviceModuleWrapper.swift` の各出現位置について、その直前で `lock()` している区間と `queue.sync` の区間の内側に無いことを、`git diff` とコードで 1 件ずつ対応付けて確認する (`grep` だけでは区間を判定できない)。
- `git diff -- Sora/Sora.swift Sora/ConnectionTimer.swift Sora/MediaChannel.swift` を読み、`complete()` の `@discardableResult -> Bool` 化、`ConnectionTimer.run` の戻り値化 (`@discardableResult` を付ける)、`MediaChannel.state` の `didSet` の削除と遷移ログの移設を確認する。
- `git diff -- Sora/MediaChannel.swift` を読み、`MediaChannel` のタイマー開始と接続試行完了の直列化 (切断完了後に遅れてタイマーを再始動する競合の防止) を壊していないことを確認する。
- `.github/workflows/e2e-test.yml` の E2E job と同じ手順でビルドとテストを実行し、失敗 0 であること。
- `make fmt-lint` と `make lint` が違反 0 であること。

## 解決方法

`## 設計方針` の表のとおり、SDK 内部の排他区間を保持したまま Logger を呼ばないようにした。

- `Sora/Sora.swift`: `add(mediaChannel:)` / `remove(mediaChannel:)` のログを `mediaChannelLock` の解放後 (handlers callback の前) へ移し、`ConnectionTask.cancel()` のログを `stateLock` の解放後へ移した。`tryComplete()` からログを削除し、`complete()` を遷移の有無を返す `@discardableResult -> Bool` にした。`Sora.connect` の設定エラー経路は `complete()` の戻り値を見て lock の外で完了ログを出す
- `Sora/ConnectionTimer.swift`: `run(timeout:handler:)` のログを削除し、その呼び出しで有効になった timeout を返すようにした (`@discardableResult`)。`stop()` のログを `stateLock` の解放後へ移した (Timer callback 内の 3 つのログは元から lock 外のため変更しない)
- `Sora/MediaChannel.swift`: `basicConnect` が `run` の戻り値を使って `connectionLifecycleLock` の解放後にタイマー開始ログを出し、`connect` / `finishConnect` / `beginDisconnect` / `finishDisconnect` が完了ログと遷移ログを lock の外で出すようにした。`state` の `didSet` からログを削除し、遷移前後 (`A` / `B`) を lock 内で確定して unlock 後に出す。完了ログと遷移ログの相対順序は現行のまま (`finishConnect` と `beginDisconnect` は完了ログ → 遷移ログ、`finishDisconnect` は遷移ログ → 完了ログ)
- `Sora/AudioDeviceModuleWrapper.swift`: `setAudioHardMute(_:)` は vendor object の操作だけを `queue.sync` で行い、戻り値を受け取ってから lock の外でログを出す
- `CHANGES.md`: `## develop` の主リストの `[FIX]` の末尾にエントリを追加した

テスト (`SoraTests/LoggerCallUnderLockTests.swift` を新規追加 (10 件)、`SoraTests/AudioDeviceModuleWrapperTests.swift` に 1 件追加):

- `Logger.shared.onOutputHandler` から同じ lock / serial queue を使う SDK の API (`mediaChannels` / `ConnectionTask.state` / `MediaChannel.disconnect(error:)` / `ConnectionTimer.isRunning` / `setAudioHardMute(_:)`) を呼ぶ経路で deadlock しないことを検証する。入口の SDK 呼び出しは専用 queue から実行し、テストスレッドは expectation を待つだけにした (退行時にテスト実行全体が停止しない)。handler の再入は 1 段に制限した。非 Sendable な instance を `@Sendable` closure へ capture しないよう box を介する
- 対象ログの到達は expectation で、`level` / `type` / `message` と経路ごとの相対順序は collector に記録した `Log` で確認する。遷移ログは `SignalingChannel` も同じ文言で出すため `type` で限定する
- 順序は `MediaChannel.beginDisconnect` の「完了ログ → 遷移ログ」を検証する。`finishDisconnect` の「遷移ログ → 完了ログ」は `beginDisconnect` を経由しない自発的な切断でしか到達せず、`ConnectionTask.cancel()` の経路では `complete()` が `false` を返すため観測できない。`finishConnect` の順序は実接続の成功が必要なため E2E の範囲とする

検証 (2026-09-28、Xcode 26.6 / Swift 6.3.3):

- 変異テスト (現行のテストで実測): `Sora.add(mediaChannel:)` のログを `mediaChannelLock` の内側へ戻すと `testAddMediaChannelFromOutputHandlerDoesNotDeadlock` が timeout で失敗し (`build/0165-polish-m1.log`)、`AudioDeviceModuleWrapper.setAudioHardMute(_:)` のログを `queue.sync` の内側へ戻すと `testSetAudioHardMuteFromOutputHandlerDoesNotDeadlock` が timeout で失敗する (`build/0165-polish-m2.log`)。完了ログを遷移の有無に関わらず出すと `testDisconnectLogsCompletionBeforeStateChange` が、完了ログの level を `.info` に変えると `testDisconnectMediaChannelFromOutputHandlerDoesNotDeadlock` が level 不一致で失敗する (`build/0165-polish-m3.log` / `build/0165-polish-m4.log`)
- `Sora/` の Swift 6 言語モードの型検査: error 0、warning 46、`#SendableClosureCaptures` 25 は実装前後で変わらない (`build/0165-typecheck.log`)
- `SoraTests` の実ビルドの concurrency 診断は実装前後で 0 件 (`0118` で解消済みの状態を退行させない。テストの入口呼び出しは box を介する)
- テスト: 対象 12 件 (新規 11 件 + 既存 1 件)・全体 401 件超 (skip 30) が失敗 0 (`build/0165-tests.log` / `build/0165-tests-full.log`)
- `make build` 成功、`make fmt-lint` / `make lint` 0 violations、`make api-check-fresh` は baseline 一致で `TestConsumers/Swift6Consumer/ApiBaseline/` に差分なし
- `grep -nE "Logger\.(fatal|error|warn|info|debug|trace)\(" Sora/{Sora,ConnectionTimer,MediaChannel,AudioDeviceModuleWrapper}.swift` の各出現位置を `git diff` と対応付け、排他区間と `queue.sync` の内側に無いことを確認した (call site を追加した箇所はすべて unlock の後)

制約:

- Thread Sanitizer は `0119` に従い完了条件に含めない
- ログの順序は同一スレッド・同一経路のみ保証し、スレッドをまたぐ順序は保証しない (状態遷移の直列化は維持)
- `Logger.shared` と `Sora.shared` はプロセス全体の共有状態のため、追加したテストは直列実行を前提とする
