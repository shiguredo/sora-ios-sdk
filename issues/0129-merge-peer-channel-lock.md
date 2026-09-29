# PeerChannel.Lock を接続状態 reducer へ統合する

- Created: 2026-09-03
- Completed:
- Priority: Medium
- Branch: feature/refactor-merge-peer-channel-lock
- Polished: 2026-09-28

## 目的

`PeerChannel.Lock` (count / isDisconnecting / isStartingConnection / shouldDisconnect を NSLock で保護) を削除し、その状態を単一の排他へ統合する。統合先は `0010` が `MediaChannel` に導入した `connectionLifecycleLock` と、`0100` が `PeerChannel` に導入した `ConnectionStateOwner` (接続状態 reducer + snapshot storage) のどちらか 1 つに決める。タイトルの「接続状態 reducer」は後者を指す。

`0100` は `Lock` を現状維持として本 issue へ送った。`0102` が追加した `webRTCConfigurationLock` も、同じ統合の判断で扱いを決める (「設計方針」)。

## 現状

`PeerChannel` には `final class Lock` があり、次を `nsLock` (NSLock) で保護している。

- `count`: `lock()` で +1、`unlock()` で -1 する進行中の非同期処理数
- `isDisconnecting`: 切断処理が開始されたことを示すフラグ。`true` の間 `lock()` は false を返す
- `isStartingConnection`: `beginConnectionStart()` から `startConnection` の開始確定までの区間を示すフラグ。区間中の切断要求は `shouldDisconnect` へ保存する
- `shouldDisconnect`: 進行中の非同期処理が終わるまで遅延させる切断要求 (error / reason)。接続試行中 (`count == 1`) かつ `onConnect` 保持中は保存せず、その場で `basicDisconnect` へ渡す

`unlock()` は `count == 0` になった場合に加えて、接続試行中 (`count == 1`) に切断要求がある場合も遅延切断を `basicDisconnect` へ渡す。猶予タイマー由来の切断は `shouldCancelDisconnectTimerBasedDisconnect` が `state` を読んで回復時にキャンセルする。`Lock` は `nsLock` を解放してから `basicDisconnect` を呼ぶ。

`0010` (`003bb738`) 以降、`MediaChannel` は `connectionLifecycleLock` で自身の接続ライフサイクルを直列化する。`0100` の `ConnectionStateOwner` は `PeerChannel` の接続状態フラグ 5 つだけを所有し、`Lock` の状態は持たない。

## 前提となる issue

`0010` (完了 2026-09-05) / `0100` (完了 2026-09-08) / `0102` (完了 2026-09-16) はすべて完了しており、着手できる。次の 2 つが確立した契約を壊さないこと。

- `0151` (完了 2026-09-28): `onConnect` を専用の `connectHandlerLock` に閉じ、接続 callback の 1 回保証を成立させた (「設計方針」の 3 条件)
- `0175` (完了 2026-09-28): `createAnswer` の handler を各 return 経路で呼ぶ契約にした (呼び出し元の `lock.unlock()` が handler に依存する)

`0177` (open) は本 issue が決める lock 順序と storage の位置を前提にするため、本 issue を先に完了させる。`0126` (open) は本 issue が先行する場合、統合先の状態機械へタイマーと強制 teardown を設計する (「スコープ外」)。

## 設計方針

- 統合先を `connectionLifecycleLock` と `ConnectionStateOwner` の比較で 1 つに決め、選定理由を「解決方法」に記録する。`ConnectionLifecycleState` には接続試行中を表す状態が無いため、接続試行状態を導入する場合は reducer の state / event の追加として行う (`0151` がこの判断を本 issue に委ねている)。`connectionLifecycleLock` を選ぶ場合は `MediaChannel` の排他が `PeerChannel` の状態を保護することになるため、`MediaChannel` から `PeerChannel` への呼び出しとの入れ子の向きも「解決方法」に記録する。
- `webRTCConfigurationLock` は接続所有の WebRTC 設定の読み書きだけを保護し、`Lock` は接続ライフサイクルの状態を保護する。保護対象が異なるため、統合時に `webRTCConfigurationLock` を統合先へ吸収するか、別 lock として残すかを決定する。
- `webRTCConfigurationLock` は `currentWebRTCConfiguration()` → `WebRTCConfigurationSnapshot.replacing(...)` → `updateWebRTCConfiguration(_:)` の read-modify-write が 3 区間に分かれており、読み出しと書き戻しの間の更新は失われる。書き込み元は `PeerChannel.createAndSendAnswer` の 1 箇所だけで、`SignalingChannel` の直列 queue 上で実行されるため現状は実害が無い。吸収する場合は差分 (iceServerInfos / iceTransportPolicy / isInsecure) を lock 内で現在値へ適用する形にまとめ、`replacing(...)` を不要にできるかを検討する。
- `PeerChannel.createAndSendAnswer` は更新後の値を再読せずローカルから `createNativePeerChannel` / `setConfiguration` / `createAnswer` へ渡しており、「この offer の設定で answer を作る」ことがコード上で保証されている。統合後もこの性質を維持する。
- 接続処理の直列化と `PeerChannel` の状態遷移を単一の ingress で処理する。
- `waitDisconnect` の遅延実行セマンティクス (接続試行中の切断要求、`count == 1` での解除、猶予タイマー発動時のキャンセル、遅延切断の上書き) を維持する。
- `basicDisconnect` を排他区間の外で呼ぶ現在の構造を維持し、接続 callback 内から同期的に `disconnect()` へ再入しても deadlock しないこと。
- `connectHandlerLock` は統合対象外として維持する。`0151` が `onConnect` 専用に導入した lock であり、保護対象が `Lock` の状態と異なる。次の 3 条件を壊さない。
  - 接続 callback の 1 回保証 (take-and-clear を 1 つの排他区間で行う)
  - 利用者 callback を `connectHandlerLock` の区間外で呼ぶ
  - `connectHandlerLock` を保持したまま他の lock を取らない
- lock 順序を一方向に固定する。現行コードでは `Lock.waitDisconnect` / `Lock.startConnection` / `Lock.unlock` が `nsLock` を保持したまま `state` を読み、`state` が `onConnect` を読むため `Lock.nsLock` → `connectHandlerLock` が必須である。統合後も「接続試行中を判定する排他 → `connectHandlerLock`」の向きだけを許し、`connectHandlerLock` を保持したまま統合先の排他を取らない。`webRTCConfigurationLock` は値の読み書きだけを行う葉の lock で、現行コードでも `Lock.nsLock` / `connectHandlerLock` / `ConnectionSnapshotStorage` と入れ子にならない (`0102` も `webRTCConfigurationLock` を保持したまま `Lock` を取らないと定めている)。統合後も `webRTCConfigurationLock` をこれらの lock と入れ子にしない。
- `0177` が `nativeChannel` / `streams` / `offerEncodings` を lock 付き storage へ移すと、`state` が `nativeChannel` を読む経路で「統合先の排他 → storage」の入れ子が生じる (現行コードでは生じない)。`state` は owner queue へ `sync` せず、lock 保持中に読める snapshot / storage 経由にし、storage を保持したまま統合先の排他を取らない。
- `createAnswer` の handler は呼び出し元の排他解放 (`lock.unlock()`) を担う (`0175`)。統合後も、`createAnswer` の各 return 経路で handler が高々 1 回、native の完了 block に委ねた経路を除き return する経路では必ず 1 回呼ばれる契約を維持する。

## 変更対象

- `Sora/PeerChannel.swift`: `Lock` (`nsLock` / `count` / `isDisconnecting` / `isStartingConnection` / `shouldDisconnect` / `waitDisconnect` / `beginConnectionStart` / `startConnection` / `shouldCancelDisconnectTimerBasedDisconnect` / `lock` / `unlock`) の削除と、統合先の排他を使う呼び出しへの置き換え (`connect` / `disconnect` / `createAndSendAnswer` / `createAndSendUpdateAnswer` / `createAndSendReAnswer` / `createAndSendReAnswerOverDataChannel` / `handleSignalingOverWebSocket(_:)` の `.offer` / `finishConnecting` / `basicDisconnect`)
- 統合先: `Sora/ConnectionLifecycle.swift` の `ConnectionStateOwner` / `ConnectionLifecycleState` / `ConnectionEvent` / `ConnectionSnapshotStorage`、または `Sora/MediaChannel.swift` の `connectionLifecycleLock`。選んだ側に必要な state / event / storage を追加する
- `Sora/PeerChannel.swift` の `webRTCConfiguration` / `webRTCConfigurationLock` / `currentWebRTCConfiguration()` / `updateWebRTCConfiguration(_:)`: 吸収する場合の差分適用
- `SoraTests/`: `peerChannel.lock` を直接使うテスト (`PeerChannelConnectCompletionTests` の `testDisconnectBeforeSignalingStartPreventsStart` / `testDisconnectDuringSignalingStartFinishesAfterOperation`) を統合後の入口へ書き換える。`connectHandlerLock` のテストは変更しない
- `CHANGES.md`: `## develop` に refactor のエントリを追加する
- lock 順序 (`Lock.nsLock` 由来の排他 → `connectHandlerLock`) は変更しない

## スコープ外

- transport 世代 (`dataChannelGeneration`) の管理 (`0100` が完了)。
- `MediaChannel` の接続 phase / callback 完了状態の管理。`0010` の `connectionLifecycleLock` が担い、統合先の決定に含めない。
- `onConnect` の排他 (`connectHandlerLock`) の統合。`0151` の変更対象であり、本 issue は 3 条件を守るだけである。
- `isAudioInputInitialized` の所有。`0173` が本 issue と `0151` に委ねた判断は `0177` が `ConnectionStateOwner` へ移す。
- 切断クリーンアップのタイムアウトと強制 teardown (`0126`)。
- `PeerChannel` 全体への `@unchecked Sendable` の付与 (`0177`)。

## テスト方針

- `Lock` の各エッジケース (接続試行中切断、`count == 1` での解除、猶予タイマーキャンセル、遅延切断の上書き、redirect 中切断) を検証する。回帰の正本は既存の `SoraTests/PeerChannelConnectCompletionTests` / `SoraTests/ConnectionTimerLifecycleTests` / `SoraTests/PeerChannelRedirectInvalidationTests` とし、統合後にこれらが成功することを確認する。lock 順序の逆転が無いことはコード読解で確認し、接続 callback 内からの `disconnect()` 再入で deadlock しないこと (`testInvokeConnectHandlerReentrantDisconnectRunsOnce`) を確認する。モックやスタブは使用しない。
- 実 Sora と実 WebRTC を使い、connect / cancel / redirect / disconnect / timeout event を反復する (ローカルは `SORA_SIGNALING_URL` 未設定で skip されるため、実 Sora の確認は CI の `e2e-test.yml` で行う)。
- Thread Sanitizer を補助的に有効化し、`0151` の `connectHandlerLock` の回帰 (`testInvokeConnectHandlerConcurrentCallsRunsOnce` / `testConcurrentInvokeConnectHandlerAndStateReadRunsOnce`) を含めてデータ競合が報告されないこと。
- `0175` の handler 契約の回帰 (`SoraTests/PeerChannelRedirectInvalidationTests.testReAnswerFromReOfferProducesAnswerMatchingOfferMediaSections`) が成功すること。
- テストには、検証するイベント順を日本語コメントで明記する。

## 完了条件

- `PeerChannel.Lock` が削除され、その状態 (count / isDisconnecting / isStartingConnection / shouldDisconnect) が統合先へ移行し、統合先の排他で保護されていること。
- 統合先の選定理由と、`webRTCConfigurationLock` の扱い (統合先への吸収、または別 lock としての存続) が「解決方法」に記録され、その方針どおりに実装されていること。
- `connectHandlerLock` が統合・削除されず維持され、「設計方針」の 3 条件が守られていること。
- lock 順序が一方向 (統合先の排他 → `connectHandlerLock`、統合先の排他 → storage) であり、逆順の入れ子と、lock 保持中の owner queue への `sync` が無いこと。
- `createAnswer` の handler 契約 (`0175`) が維持されていること。
- 統合先 (`0100` / `0010`) の完了条件が引き続き満たされていること。
- 既存の全テストが成功すること。

## 解決方法
