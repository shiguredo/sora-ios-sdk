# type: notify で更新される接続人数の状態競合を修正する

- Created: 2026-09-03
- Completed: 2026-11-10
- Priority: Medium
- Branch: feature/fix-notify-connection-count-races
- Polished: 2026-11-10
- Refreshed: 2026-11-10

## 目的

`MediaChannel` の `connectionCount` / `publisherCount` / `subscriberCount` は `type: notify` 受信時に WebSocket の受信スレッドまたは DataChannel シグナリング利用時の DataChannel の delegate スレッドから更新され、利用者が任意のスレッドから同期 getter で読む。現状は NSLock の保護がなく、データ競合のリスクがある。NSLock で保護する。

## 現状

- 更新元: `MediaChannel.basicConnect(connectionTask:)` が `peerChannel.internalHandlers.onReceiveSignaling` に設定する closure の `.notify` 分岐。この closure は `PeerChannel.handleSignalingOverWebSocket(_:)` と `PeerChannel.handleSignalingOverDataChannel(_:)` から呼ばれる
- 更新スレッド: WebSocket 経由は `SignalingStateOwner` が作る直列の `OperationQueue` (`jp.shiguredo.sora-ios-sdk.websocket-delegate`) 上で処理される。DataChannel シグナリング利用時は libwebrtc の DataChannel delegate スレッドから呼ばれる
- 読む側: 利用者の同期 getter (`connectionCount` / `publisherCount` / `subscriberCount`。任意スレッド)
- 保護: なし

## 設計方針

- `MediaChannel` に 3 値を保護する NSLock を追加する。stored property のままでは getter を lock 配下にできないため、3 値は `state` と同じく `get` / `set` を明示した `public private(set) var` の computed property にし、`set` は lock 配下で値を書く private メソッドへ集約する。lock は `dataChannelOpenLock` / `MediaChannelStateStorage` と同じく、保持したまま他の lock を取らない葉 lock として扱う。
- 更新 (`connectionCount` / `publisherCount` / `subscriberCount` の代入) はロック配下で行う。
- getter の読み出しも lock 配下で行う。
- handler (`onReceiveSignaling`) の呼び出しはロックの外で行う (利用者コードがロックを保持したまま実行されないようにする)。
- これは `0100` (PeerChannel の接続状態フラグの所有者を単一化する、完了 2026-09-08) のスコープ外として確定した事項であり、`0100` はこの 3 値を本 issue に委ねている。本 issue は `0100` とは独立に実装する。

## スコープ外

- `state` / `connectionStartTime` は本 issue では扱わない。MediaChannel の接続ライフサイクルは `0010` の `connectionLifecycleLock` による直列化を正とし、`state` は `0180` (完了 2026-10-05) で `MediaChannelStateStorage` (NSLock 付き storage) を読む computed property になり、書き込みは `connectionLifecycleLock` を保持した区間の `setState(_:)` に限られる。`connectionStartTime` は `connectionLifecycleLock` を保持した区間で書くが、`connectionTime` は lock を取らずに読む。本 issue で扱うのは `connectionCount` / `publisherCount` / `subscriberCount` のみ
- `onReceiveSignaling` の Sendable 化は `0110` (完了 2026-10-07) では行われていない。`0110` は legacy handler の型を変更せず、Sendable な event API (`MediaChannel.subscribeEvents(bufferingPolicy:)` / `SoraEvent`) を追加した。接続人数の event 化は本 issue では扱わない。

## 変更対象

- `Sora/MediaChannel.swift`: 3 値を保護する NSLock と computed property の追加、`.notify` 分岐の更新
- `SoraTests/`: 更新と読み出しを複数スレッドから交差させる concurrency テストの追加
- `TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json` / `iphoneos26.5.info.txt`: computed property 化で公開 ABI の dump が変わるため、`make api-baseline` で再生成する

## テスト方針

- 更新と読み出しを複数スレッドから並行して行う concurrency テスト (Thread Sanitizer 有効) を追加する。モックやスタブは使用しない。
- 実 Sora からの notify 受信で、更新が正しく反映されることを確認する。

## 完了条件

- `connectionCount` / `publisherCount` / `subscriberCount` が NSLock で保護されること。
- 追加した concurrency テストを Thread Sanitizer 有効で実行し、データ競合が検出されないこと。
- `make api-check-fresh` が成功すること。
- 既存の全テストが成功すること。

## 解決方法

`connectionCount` / `publisherCount` / `subscriberCount` を NSLock で保護し、`.notify` の更新を 1 回のロック区間にまとめた。

- `Sora/MediaChannel.swift`
  - `connectionCountsLock` と 3 値の保持領域を追加し、3 プロパティを `public private(set)` の computed property に変更した。getter / setter は `withConnectionCountsLock` で lock を取る。
  - `.notify` の更新を `updateConnectionCounts(connectionCount:publisherCount:subscriberCount:)` に集約し、3 値を 1 回のロック区間で書くようにした。setter は `private(set)` の公開 API 形状を維持するためだけに残し、production の更新は `updateConnectionCounts` に限定した。
  - `.notify` の 4 値 guard と publisher / subscriber の計算を `connectionCounts(from:)` に、受信処理を `handleSignaling(_:)` に切り出し、実接続なしでテストできるようにした。空の `else` と 4 フィールドを列挙するだけのコメントを削除した。
  - 公開 3 プロパティの doc に、任意スレッドから読み出せること、3 つの getter をまとめて読むスナップショット API が無いこと、同じ notify の 4 値は `onReceiveSignalingJSON` で受信できることを追記した。
- `SoraTests/MediaChannelConnectionCountTests.swift` (新規)
  - 実 `Signaling.decode` と実 `MediaChannel` を使い、`.notify` の 4 値から 3 値への導出、フィールド欠落時の非更新、`updateConnectionCounts` の引数と getter の対応、`onReceiveSignaling` への転送を検証する 5 テストを追加した。モック・スタブは使用していない。
- `SoraTests/ConcurrencyStressTests.swift`
  - `testConnectionCountsReadWriteRace` を追加し、64 並行 × 8 ラウンドで更新と読み出しを交差させた。初期 seed を削除し、最終状態を `XCTUnwrap` と `publisherCount + subscriberCount == iterations` で検証するようにした。
- `CHANGES.md` / `skills/sora-ios-sdk/SKILL.md`
  - `## develop` に `[FIX]` エントリを追加し、SKILL.md の MediaChannel 表に getter の thread safety とスナップショット非保証を追記した。
- `TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json`
  - Xcode 26.6 / iphoneos26.5 で `make api-baseline` を実行して再生成した。差分は 3 プロパティの ABI 属性 (`HasStorage` / `HasInitialValue` / getter の `implicit` / `Transparent` の消失) だけで、他の symbol の差分は無い。

検証:

- 手元の Xcode 27.0 / iphoneos27.0 で `make build XCODE_SDK=iphoneos27.0` が成功した
- SoraTests 全件: 571 件実行 / 40 件 skip / 失敗 0
- 追加テスト (`MediaChannelConnectionCountTests` 5 件 + `testConnectionCountsReadWriteRace`): 成功
- Thread Sanitizer 有効の `testConnectionCountsReadWriteRace`: 成功、`WARNING: ThreadSanitizer` 0 件
- ネガティブコントロール (実装時): `updateConnectionCounts` の lock を外すと TSan が write-write race を検出し、テストが失敗することを確認
- `swift format lint --strict` / `swiftlint --strict`: 0 violations
- `make api-check-fresh` (Xcode 26.6 / iphoneos26.5): 成功

実 Sora からの notify 受信による確認は、Sora の接続環境が必要なため未実施である。`.notify` の 4 値 guard・計算・ハンドラ転送は、実 `Signaling.decode` を使う単体テストで確認している。
