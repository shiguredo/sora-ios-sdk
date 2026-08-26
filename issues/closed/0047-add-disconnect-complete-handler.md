# 切断処理の完了を示すイベントハンドラを追加する

- Priority: Medium
- Created: 2026-06-06
- Completed: 2026-08-25
- Model: Sonnet 4.6
- Branch: feature/add-disconnect-complete-handler
- Polished: 2026-08-25

## 目的

`basicDisconnect()` の主要なクリーンアップ（`signalingChannel.disconnect()` による WebSocket クローズを含む）が完了した後に発火する `onDisconnectComplete` ハンドラを `MediaChannelHandlers` に追加する。アプリ側が「サーバー側のチャンネルが解放されるタイミングに最も近い時点」を検知できるようにし、安全な再接続を可能にする。

## 優先度根拠

切断完了ハンドラの欠如は `0042`（DUPLICATED-CHANNEL-ID）の根本原因の一つ。本 issue は 0042 の設計方針 A（根本解決策）として参照されている。0042 では方針 B（`Sora.connect()` レベルの防衛的ガード）は見送りが確定しており（`0042` の設計方針を参照）、本 issue が残る唯一の解決手段である。そのため Medium とする。

## 現状

SDP ハンドシェイク等の非同期処理が進行中（`lock.count > 0`）に切断が発生すると:

1. `MediaChannel.internalDisconnect()`（`MediaChannel.swift:586`）が `state = .disconnecting` をセットして `peerChannel.disconnect()` を呼ぶ
2. `peerChannel.disconnect()` は `Lock.waitDisconnect()`（`PeerChannel.swift:125`）を実行する。`count` の値により分岐する（`PeerChannel.swift:129-159`）:
   - `count == 0` の場合: `basicDisconnect()` を同期実行してから返る
   - `count == 1` かつ `onConnect != nil`（接続試行中）の場合: 初期ロックを解放して `basicDisconnect()` を同期実行してから返る（`PeerChannel.swift:137-145`）
   - それ以外（`count >= 2`、例えば answer 作成中。または `count == 1` かつ `onConnect == nil`、例えば接続完了後の非同期処理中）の場合: `shouldDisconnect` にパラメータを保存するだけで即座に返る（`basicDisconnect()` は未実行）
3. `internalDisconnect()` 続行: `state = .disconnected`（`MediaChannel.swift:612`）、`handlers.onDisconnect` がアプリに発火（`MediaChannel.swift:641`）
4. **アプリが `onDisconnect` を受けて即座に `connect()` を呼ぶ**
5. ところが `basicDisconnect()` はまだ実行されておらず、WebSocket も未クローズ（`signalingChannel.disconnect()` 未実行）
6. サーバーは旧接続が生きていると認識しているため `DUPLICATED-CHANNEL-ID` が発生

遅延実行された `basicDisconnect()` は、進行中の非同期処理の完了時の `Lock.unlock()`（`PeerChannel.swift:191-222`）から実行される。

`count == 0` と接続試行中（`count == 1` かつ `onConnect != nil`）の場合は `peerChannel.disconnect()` 内で `basicDisconnect()` が同期実行されてから返るため上記の問題は発生しないが、両経路で一貫したタイミング制御を提供するために `onDisconnectComplete` を追加する。

### `basicDisconnect()` の関連する処理順序

`PeerChannel.basicDisconnect()`（`PeerChannel.swift:1482`）の該当区間は以下の順に実行される:

- `sendDisconnectMessageIfNeeded(reason:error:)`（`PeerChannel.swift:1504`）: サーバーへの `type: disconnect`（NO-ERROR）送信。サーバー側セッション解放の実操作
- `signalingChannel.disconnect()`（`PeerChannel.swift:1548`）: WebSocket クローズ（`webSocketTask.cancel()` + `urlSession.invalidateAndCancel()` を呼ぶ。`URLSessionWebSocketChannel.swift:98-99`）。DataChannel シグナリング構成では WebSocket は既に閉じている場合があり、DataChannel のクローズ処理が実行される
- `internalHandlers.onDisconnect?(error, reason)`（`PeerChannel.swift:1551`）
- `onConnect?(error)` 呼び出し（`PeerChannel.swift:1553-1559`。接続試行中に切断が発生した場合のみ）
- 後始末（`dataChannelSignalingClose = nil` / `webSocketDisconnectScheduled = false`、`PeerChannel.swift:1561-1563`）

`basicDisconnect()` は `Lock.isDisconnecting` ガードにより一度の接続につき高々一度しか呼ばれない。ただし**ゼロ回もあり得る**。なお `count == 0` の場合でも、猶予タイマー由来の切断（`reason == .peerConnectionStateDisconnected`）で接続が回復済みの場合は `basicDisconnect()` が実行されない（詳細は設計方針の「発火しない場合について」を参照）。

## 設計方針

**案 A（採用）**: `MediaChannelHandlers` に `onDisconnectComplete: (() -> Void)?` を追加する。

案 A を採用する理由:
- ユーザー起因・サーバー起因・タイムアウト起因いずれの切断でも発火する（`internalDisconnect()` は各経路から呼ばれる。`ConnectionTask.cancel()`（`Sora.swift:434-441`）も `peerChannel.disconnect()` を直接呼び、`basicDisconnect()` 内の `signalingChannel.disconnect()` に含まれる `SignalingChannel.internalHandlers.onDisconnect?`（`PeerChannel.swift:1548` → `SignalingChannel.swift:319`）を経由して `MediaChannel.swift:436-444` のクロージャが接続試行中（`state == .connecting`）のため `internalDisconnect()` へ再入する。なお `PeerChannel.swift:1551` の `internalHandlers.onDisconnect?`（`MediaChannel.swift:446-454` に対応）の時点では MediaChannel.state は既に `.disconnected` のため再入しない。したがって接続試行中でも `handlers.onDisconnect?` と共に発火する）
- 案 B（`disconnect(completionHandler:)` 引数）はユーザー起因の切断にしか対応できず、サーバー起因の切断後の再接続を安全にできない。`disconnect(error:)` へのオーバーロード追加なら既存呼び出しの互換性を保つことは可能だが、サーバー起因・タイムアウト起因の切断では待機対象の呼び出しが存在しないため意味がない

**`onDisconnect` との役割の差異**:
- `onDisconnect`: `MediaChannel.internalDisconnect()`（`MediaChannel.swift:586`）の中で、`internalHandlers.onDisconnectLegacy?` / `handlers.onDisconnectLegacy?`（`MediaChannel.swift:615-616`、deprecated）に続いて `handlers.onDisconnect?(disconnectEvent)`（`MediaChannel.swift:641`）として発火。`count` 次第で `basicDisconnect()` 完了前に発火する場合がある。切断の通知・UI 更新・ログ記録を行う用途
- `onDisconnectComplete`: `PeerChannel.basicDisconnect()` 内の通知系処理（`internalHandlers.onDisconnect?` と `onConnect?` 呼び出し）の実行後に発火。`signalingChannel.disconnect()` の呼び出し（WebSocket クローズ要求の発行。送出完了は OS 依存の best-effort）は完了している。再接続のタイミング制御に使用する用途。引数なし（`() -> Void`）とする。切断理由・エラー情報が必要な場合は、先に発火する `onDisconnect` の `SoraCloseEvent` をアプリ側で保持すれば参照できる

**他 SDK との比較メモ**:
- Android SDK: `SoraMediaChannel.Listener.onClose(mediaChannel, closeEvent)`（`SoraMediaChannel.kt:386`）の単一イベントで切断通知（完了専用ハンドラはない。切断完了をタイミング付きで検知する手段がない）
- Flutter SDK: `disconnect()` は teardown 完了まで await でき、teardown 完了時点で `SoraDisconnectedState` イベントが発火する（`sora_connection.dart`）

他 SDK は「切断通知と完了を区別しない」または「await で完了を表現する」設計であり、「通知と完了の分離」が必要になるのは iOS SDK の `Lock` による遅延実行構造が原因である。そのため `onDisconnectComplete` を他 SDK の API 形状に揃える必要はなく、iOS のコールバックベースの API スタイルに合わせて追加する。

**`internalHandlers` と `handlers` の扱い**:
`internalDisconnect()` では `internalHandlers.onDisconnectLegacy?`（`MediaChannel.swift:615`、`Sora.swift:181` で Sora の `remove(mediaChannel:)`（`Sora.swift:146` / `:188`）と `SoraHandlers.onDisconnect?`（`:189`）への通知に接続済み）、`handlers.onDisconnectLegacy?`（`:616`、deprecated）、`handlers.onDisconnect?(disconnectEvent)`（`:641`）の 3 つを呼ぶ。`MediaChannel.internalHandlers` 側の新形式（`SoraCloseEvent`）の onDisconnect には何も設定されていない。`onDisconnectComplete` も同様に `handlers.onDisconnectComplete?()` のみを呼ぶ。`internalHandlers.onDisconnectComplete` は追加しない。

**`onDisconnect` → `onDisconnectComplete` の発火順序の保証**:

発火要求は 2 つのスレッドから生じる。`internalDisconnect()` を実行するスレッド A と、遅延実行された `basicDisconnect()`（`Lock.unlock()` 経由）を実行するスレッド B である。`state == .disconnected` のような状態判定だけでは、A と B の競合時に「`onDisconnect` より先に `onDisconnectComplete` が発火する」「`onDisconnectComplete` が二重に発火する」ことを防げない（`state = .disconnected`（`MediaChannel.swift:612`）から `handlers.onDisconnect?`（`:641`）までの間にユーザーコードが挟まり、その間に B が `basicDisconnect()` を完了させる場合）。そのため、一度きり発火を構造的に保証するフラグとロックを用いる。

`MediaChannel` にインスタンスプロパティを追加する:

```swift
// フラグは basicConnect() 開始時（connectionTask.peerChannel = peerChannel の直後）に
// disconnectCompleteLock の配下でリセットする。
// なお MediaChannel は Sora.connect() が毎回新規生成するため通常は初期値のまま使われる
// (リセットは防御的配置)。
private var basicDisconnectCompleted = false
private var onDisconnectNotified = false
private var onDisconnectCompleteNotified = false
// 上記フラグの読み書きのみを保護し、ハンドラ呼び出しはロックの外で行うこと
private let disconnectCompleteLock = NSLock()
```

`MediaChannel.basicConnect()` 内で `peerChannel.internalHandlers.onDisconnect` を設定している箇所（`MediaChannel.swift:446-454`。同 `basicConnect()` 内には `signalingChannel.internalHandlers.onDisconnect` の設定もあるが、本 issue では `peerChannel.internalHandlers` 側）の直後に `onBasicDisconnectComplete` ハンドラを追加する:

```swift
peerChannel.internalHandlers.onBasicDisconnectComplete = { [weak self] in
    guard let weakSelf = self else { return }
    var shouldFire = false
    weakSelf.disconnectCompleteLock.lock()
    weakSelf.basicDisconnectCompleted = true
    if weakSelf.onDisconnectNotified, !weakSelf.onDisconnectCompleteNotified {
        weakSelf.onDisconnectCompleteNotified = true
        shouldFire = true
    }
    weakSelf.disconnectCompleteLock.unlock()
    if shouldFire {
        weakSelf.handlers.onDisconnectComplete?()
    }
}
```

`internalDisconnect()` 内の `handlers.onDisconnect?(disconnectEvent)` 発火後（`MediaChannel.swift:641` の直後）に以下を追加する（既存の 641 行目は変更せず、`switch state` の `default` 分岐内（`:591-642`）・`handlers.onDisconnect?(disconnectEvent)` の直後に挿入する。分岐の外に置くと、`.disconnecting` / `.disconnected` の早期 return 経由でも `onDisconnectNotified` が立ってしまい本設計の前提が崩れる）:

```swift
// basicDisconnect が完了済み（同期パス）なら onDisconnectComplete もここで発火
var shouldFire = false
disconnectCompleteLock.lock()
onDisconnectNotified = true
if basicDisconnectCompleted, !onDisconnectCompleteNotified {
    onDisconnectCompleteNotified = true
    shouldFire = true
}
disconnectCompleteLock.unlock()
if shouldFire {
    handlers.onDisconnectComplete?()
}
```

この方式の発火順序:
- **同期パス（`count == 0` / `count == 1` かつ `onConnect != nil` の接続試行中）**: `basicDisconnect()` 同期実行（スレッド A）→ `onBasicDisconnectComplete` で `basicDisconnectCompleted = true`（この時点で `onDisconnectNotified` は false のため発火しない）→ `peerChannel.disconnect()` 返る → `state = .disconnected` → `handlers.onDisconnect?` 発火 → 直後のチェックで `onDisconnectNotified = true` かつ `basicDisconnectCompleted = true` のため `handlers.onDisconnectComplete?()` 発火
- **遅延パス（それ以外）**: `peerChannel.disconnect()` 即座に返る → `state = .disconnected` → `handlers.onDisconnect?` 発火（この時点で `basicDisconnectCompleted` は false のため `onDisconnectComplete` はまだ発火しない）→ 後でスレッド B が `basicDisconnect()` 実行 → `onBasicDisconnectComplete` → `onDisconnectNotified` が true で、未通知のため `handlers.onDisconnectComplete?()` 発火

どのパスでも「`handlers.onDisconnect?` 発火 → `handlers.onDisconnectComplete?` 発火」の順序と 1 回性が保証される。`internalDisconnect()` が `.disconnecting` / `.disconnected` の状態で呼び出された場合（`MediaChannel.swift:588-590`）は何も実行しないため、`handlers.onDisconnect?` の再発火は防止される（二重切断の吸収）。`onDisconnectComplete` の二重発火は `onDisconnectCompleteNotified` フラグにより構造的に不可能である。

**純粋関数への分離**:
発火判定（両フラグ成立 && 未通知）は、`shouldNotifyDataChannelAvailable` の前例（`MediaChannel.swift:727-781`。状態を持たない純粋関数と、ロック保持・フラグ更新・判定を内包する `...Locked()` wrapper の 2 段構成）に倣い、状態を持たない純粋関数として分離した上で、2 箇所それぞれの固定処理（`basicDisconnectCompleted = true` または `onDisconnectNotified = true` のセット + 判定 + `onDisconnectCompleteNotified` 設定）をラッパー関数で共通化する。doc コメントには「状態を持たない純粋関数であり、単体テストの対象です」を記載する。

**発火しない場合について**:
`onDisconnectComplete` は `basicDisconnect()` が実行された場合のみ発火する。発火しない経路は以下の 3 つである:

- 猶予タイマー由来の切断の回復キャンセル（`PeerChannel.swift:131-136` / `194-199`）: `basicDisconnect()` が実行されないため、`handlers.onDisconnect?` も発火しない（接続が回復しており、アプリには切断として通知されない）
- `Lock.unlock()` の `state == .closed && !isRedirecting` ガード通過時（`PeerChannel.swift:218`）: `shouldDisconnect` が保存済みでも `basicDisconnect()` が実行されず、`handlers.onDisconnect?` は発火済みだが `onDisconnectComplete` が発火しないことがある（到達条件はリダイレクト窓との複合ケース）
- `ConnectionTask.cancel()` が `connectionTask.peerChannel = peerChannel` の設定**前**に実行された場合: `peerChannel?` が nil のため切断処理が走らず、接続はそのまま継続する（`onDisconnect?` も `onDisconnectComplete?` も発火しない既存挙動）

また以下の注意事項がある:

- 遅延パスでは `onDisconnect` 発火時点で `Sora` の管理（`_mediaChannels`）からは既に除去されている（`MediaChannel.swift:615` → `Sora.swift:181` の `remove(mediaChannel:)` 経由）ため、**アプリ側で MediaChannel への強参照を保持しないと、後から実行される `onBasicDisconnectComplete` の `[weak self]` が nil になり、`onDisconnectComplete` が発火しない**。アプリは `onDisconnectComplete` の発火を待つ間、MediaChannel を保持すること
- アプリ側は `onDisconnectComplete` への依存を避け、待ち合わせが必要な場合はタイムアウトを設けること

**スレッドセーフ性**:
`count > 0` のケースでは `basicDisconnect()` は WebRTC スタックの任意スレッドから実行される可能性がある。`internalDisconnect()` が別スレッドから呼ばれる場合も考慮すると、上記 3 フラグへの concurrent アクセスが起き得る。`MediaChannel` 内の既存ロック（`dataChannelOpenLock`、`MediaChannel.swift:209`）と同じく `NSLock` でフラグ読み書きを保護する（`OSAllocatedUnfairLock` は SDK の最小展開バージョンである iOS 14 では利用不可のため採用しない）。ハンドラ呼び出しはロックの外で行う（既存規約: `MediaChannel.swift:208` および `Sora.swift:127-129`）。

**`PeerChannelInternalHandlers` への追加**:
`PeerChannelInternalHandlers`（`PeerChannel.swift:48`）に `onBasicDisconnectComplete: (() -> Void)?` プロパティを追加する。`basicDisconnect()` 内では、前述の処理順序の `onConnect?(error)` 呼び出し（`PeerChannel.swift:1553-1559`）の**後**、後始末（`PeerChannel.swift:1561-1563`）の前に `internalHandlers.onBasicDisconnectComplete?()` を呼ぶ。この位置なら「`internalHandlers.onDisconnect?` の後」「`onConnect?(error)`（接続失敗の最終通知）の後」の両方が保証される。

**doc コメントの要件**:
`onDisconnectComplete` の doc コメントには、以下を明記する:

- 既存 `onDataChannel`（`MediaChannel.swift:57`）と同じく「呼び出し元のスレッドは保証されないため、必要に応じて main キューに束ねること」
- 発火条件と発火しない場合（回復キャンセル等）があること
- 遅延パスでは `onDisconnectComplete` 発火まで MediaChannel への強参照を保持する必要があること

なお既存 `onDisconnect`（`MediaChannel.swift:33`）の doc コメントにはスレッド保証の記載がないが、`internalDisconnect()` の呼び出し経路（ユーザー起因・`ConnectionTask.cancel()`・サーバー起因）により発火スレッドが異なるため、同じ要件（スレッドの保証はない旨）を `onDisconnect` の doc コメントにも追記する。

## 完了条件

- `MediaChannelHandlers` に `onDisconnectComplete: (() -> Void)?` が追加されていること
- `onDisconnectComplete` は `basicDisconnect()` の `signalingChannel.disconnect()` 呼び出し後に発火すること（`onDisconnect` より先には発火しないこと）
- `onDisconnectComplete` は 1 回のみ発火すること（`basicDisconnect()` の実行パス・スレッドによらず）
- 発火しない場合（猶予タイマー由来の切断の回復キャンセル等）と、MediaChannel への強参照保持が必要な旨が仕様として明記され、doc コメントに記載されていること
- `onDisconnectComplete` ハンドラ内で `connect()` を呼んだ場合に `DUPLICATED-CHANNEL-ID` が発生しないこと（WebSocket シグナリング構成・通常条件下で。サーバー側の旧接続解放には TCP レベルのラグが存在するため完全な保証ではない。DataChannel シグナリング構成はスコープ外）
- フラグへの concurrent アクセスが `NSLock` で保護され、ハンドラ呼び出しがロックの外で行われること
- 発火判定が純粋関数として分離され、真理値表の単体テストが追加されていること
- `onDisconnectComplete` の doc コメントに「呼び出し元のスレッドは保証されないため、必要に応じて main キューに束ねること」が明記されていること。`onDisconnect` の doc コメントにも同様の条項が追記されていること
- `CHANGES.md` の `## develop` セクションにある `[ADD]` エントリ群の末尾（`isSpotlightEnabled` エントリ（`CHANGES.md:32-34`）の直後）に追記すること（エントリ文言は解決方法を参照）。0042 の `[FIX]` エントリも同じ PR で追記すること（0042 側はコード変更を含まず、本 issue の実装 PR が追記先）

## 解決方法

### 実装

設計方針のコード例どおりに、以下の 8 項目を実装する。要点のみ:

1. `MediaChannelHandlers`（`MediaChannel.swift:20-69`）への `public var onDisconnectComplete: (() -> Void)?` 追加
2. `PeerChannelInternalHandlers`（`PeerChannel.swift:48`）への `onBasicDisconnectComplete: (() -> Void)?` 追加
3. 発火順序保証の 3 フラグ + `disconnectCompleteLock`、純粋関数 `shouldNotifyDisconnectComplete`（仮称）とラッパー関数
4. `basicConnect()` でのフラグリセット（`connectionTask.peerChannel = peerChannel` の直後、ロック配下）
5. `basicDisconnect()` の `onConnect?` 呼び出しの後に `internalHandlers.onBasicDisconnectComplete?()` を呼ぶ
6. `internalDisconnect()` の `switch state` の `default` 分岐内、`handlers.onDisconnect?(disconnectEvent)`（`MediaChannel.swift:641`）の直後に発火チェックを挿入する
7. `onDisconnect` / `onDisconnectComplete` の doc コメント更新
8. `CHANGES.md` への追記（E2E テスト追加は開発用変更のため、`### misc` セクションにも E2E テスト追加の `[ADD]` エントリを追記する）

```
- [ADD] 切断処理完了後に呼ばれる MediaChannelHandlers.onDisconnectComplete ハンドラを追加する
  - @voluntas
```

### テスト

- **単体テスト**: 発火判定の純粋関数の真理値表テストを `DataChannelNotificationTests.swift` の前例に倣い `SoraTests` に追加する。3 フラグの 8 組のうち、不変条件（`onDisconnectCompleteNotified == true` には `basicDisconnectCompleted == true` かつ `onDisconnectNotified == true` が必要）を満たさない 3 組を到達不能として除外し、到達可能な 5 組を検証する
- **E2E テスト**（`SoraTests/` の `E2ETestBase.swift` と既存の切断 E2E の構成に倣う）:
  - ユーザー起因の切断で `onDisconnect` → `onDisconnectComplete` の順序と各 1 回発火を検証する
  - サーバー起因の切断（Sora API の DisconnectConnection）で同様の順序と各 1 回発火を検証する（既存 `testSendonlyReconnect`(`SendonlyE2ETests.swift:301`) を変更して検証する）
  - `onDisconnectComplete` 発火を再接続トリガーにし、接続が成功することを検証する（1 秒待機を発火待ちに置き換える。これは上記の `testSendonlyReconnect` の変更に組み込む）
- 発火回数と順序の確定は、main queue 上で発火履歴を配列に記録し、すべての期待発火が終息した後に行う最終検証（`finalVerify` 方式、`SendonlyE2ETests.swift:573-579` の前例）で行う
- 遅延パス（`count >= 2` 中の切断）は E2E での意図的な再現が難しいため、純粋関数の真理値表と実装レビュー（発火経路のトレース）で担保する

### 実装結果

- ブランチ `feature/add-disconnect-complete-handler` で実装済み。変更ファイル:
  - `Sora/MediaChannel.swift`: `MediaChannelHandlers.onDisconnectComplete` 追加、3 フラグ + `NSLock`（`withDisconnectCompleteLock`）、純粋関数 `shouldNotifyDisconnectComplete` と `mark*Locked`、発火チェック
  - `Sora/PeerChannel.swift`: `PeerChannelInternalHandlers.onBasicDisconnectComplete` 追加、`basicDisconnect()` 内での呼び出し
  - `SoraTests/DisconnectCompleteNotificationTests.swift`: 真理値表 5 組（到達不能 3 組を除外）の単体テスト
  - `SoraTests/SendonlyE2ETests.swift`: `testSendonlyDisconnectComplete` 追加、`testSendonlyReconnect` の 1 秒待機を発火待ちに置き換え
  - `CHANGES.md`: `[ADD]` エントリ、0042 の `[FIX]` エントリ、misc の E2E エントリ
- 検証済み: Swift 6 モードのビルド（BUILD SUCCEEDED）、単体テスト 5 件（iPhone シミュレータで TEST SUCCEEDED）、swift-format / SwiftLint
- 未実行: E2E テストは実サーバー（Sora + Sora API）が必要なため未実行。`SORA_SIGNALING_URL` / `TEST_API_URL` / `TEST_SECRET_KEY` を設定した CI で確認すること
