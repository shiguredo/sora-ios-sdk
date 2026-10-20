# PeerChannel.Lock を接続状態 reducer へ統合する

- Created: 2026-09-03
- Completed: 2026-09-29
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

`PeerChannel.Lock` を削除し、その状態を `Sora/ConnectionLifecycle.swift` の `ConnectionStateOwner` へ統合した。

### 統合先の決定と理由

統合先は `ConnectionStateOwner` (接続状態 reducer + snapshot storage) とした。`MediaChannel.connectionLifecycleLock` を選ばなかった理由は次の 3 点である。

- `PeerChannel` は `MediaChannel` を持たない状態でも構築され、テスト (`PeerChannelConnectCompletionTests` / `ConnectionTimerLifecycleTests` / `PeerChannelConnectEncodingTests` / `ConnectionConfigurationSnapshotTests` 等) はすべて `mediaChannel: nil` で実 `PeerChannel` を動かす。`connectionLifecycleLock` を統合先にすると、`mediaChannel == nil` の経路に別の排他を用意することになり、「単一の排他へ統合する」という目的を満たせない
- `connectionLifecycleLock` は `MediaChannel` の接続 phase / callback 完了状態を守る lock であり、`PeerChannel` の接続試行状態を守らせることは、`MediaChannel` の排他が `PeerChannel` の状態を保護する結合を生む。`0010` が「MediaChannel の接続ライフサイクルは `connectionLifecycleLock` が担う」と定め、`0100` が「PeerChannel の接続状態は `ConnectionStateOwner` が担う」と定めた分担を崩す
- `Lock` の状態は `PeerChannel` の接続状態フラグと同じ接続単位の状態であり、`ConnectionStateOwner` の直列 queue に載せると `0100` の ingress が 1 つにまとまる。`0151` が `0129` へ委ねた「接続試行中を表す状態を reducer の state / event の追加として行う」もこの選択で満たせる

### 統合の設計

- `ConnectionLifecycleState` に `asyncOperationCount` / `isDisconnecting` / `isStartingConnection` を追加し、`ConnectionEvent` に `connectionStartBegan` / `signalingStartFinished` / `signalingStartCancelled` / `asyncOperationBegan` / `asyncOperationEnded` / `disconnectAccepted` / `disconnectAcceptedWhileConnecting` を追加した。すべて `ConnectionStateReducer` が遷移を決める
- `asyncOperationCount` は接続開始の初期ロックも 1 つの非同期処理として数える。旧 `Lock` が `count` 1 つで「初期ロック + 進行中の非同期処理」を管理し、切断要求を遅延させる判断 (`count == 0` か接続試行中の `== 1` か) を同じ数で行っていたためである。増減の入口は `beginConnectionStart` / `beginAsyncOperation` (`+1`)、`endAsyncOperation` (`-1`)、接続開始が失敗する `sendConnectMessage(error:)` (初期ロックを `-1`)
- 接続ライフサイクルのイベントは `ConnectionEffect.publishSnapshot` を返さない。接続試行状態を読む同期 getter が無く (`PeerChannel` が snapshot storage から読むのは `transportEpoch` / `isRedirecting` / `webSocketDisconnectScheduled` / `disconnectTimerScheduled` / `disconnectTimerGeneration` の 5 つだけ)、publish しても NSLock の取得を増やすだけである。接続状態フラグを変えるイベントだけが publish する
- 遅延させる切断要求 (`shouldDisconnect`) は `Error` を保持するため snapshot には載せず、`ConnectionStateOwner` の private な `pendingDisconnect` として同じ直列 queue 上でのみ読み書きする。`isDisconnecting == true` ならば `asyncOperationCount == 0` という関係は不変条件ではない (切断要求の受理時に進行中の非同期処理があれば、その数は 0 にならない)。到達可能な状態でだけ成り立つ呼び出し側の契約として、`isDisconnecting` を立てる条件 (残高 0、または接続試行中の初期ロックの強制解放) と、`isDisconnecting` 中の `endAsyncOperation` が残高と遅延要求を変えないことを doc に書く
- `Lock` の各メソッドは `ConnectionStateOwner` の同期 API (`beginConnectionStart` / `prepareSignalingStart` / `finishSignalingStart` / `beginAsyncOperation` / `endAsyncOperation` / `requestDisconnect`) へ移した。排他は専用の `NSLock` ではなく `eventQueue.sync` (serial `DispatchQueue`) である。check-then-act の判定と state の更新は同じ `sync` 区間で行う
- `waitDisconnect` の遅延実行セマンティクスは、`requestDisconnect` が即時実行できない要求を `pendingDisconnect` に保存し、`endAsyncOperation` が `asyncOperationCount == 0` (または接続試行中の `== 1` で要求あり) のときに取り出して返すことで維持する。猶予タイマー発動時のキャンセル判定と、遅延切断の上書きも `requestDisconnect` の分岐をそのまま移した
- 保存された切断要求の確定は `resolvePendingDisconnect(acceptedEvent:shouldCancelDisconnectTimerBasedDisconnect:)` に集約した。共通化したのは「保存を破棄して取り消すか、イベントを適用して実行するか」の判断だけであり、適用するイベントは呼び出し側が引数で選ぶ (`prepareSignalingStart` と `finishSignalingStart` は `.signalingStartCancelled`、`endAsyncOperation` は `.disconnectAcceptedWhileConnecting`)。`isDisconnecting` のガード位置、`.signalingStartFinished` の無条件適用とその位置、`.ignored` の扱い、戻り値の意味づけは呼び出し側に残した
- `endAsyncOperation` の残高の破綻検出は `isDisconnecting` の判定の後、残高を減らす前に置いた。旧 `Lock.unlock()` は `isDisconnecting` の場合に減算せずに戻っていたため、破綻の検出は「切断処理が開始されていないとき」に限られていた。`isDisconnecting == true` の間に残高が 0 のまま `endAsyncOperation` が呼ばれる経路 (残高 2 以上で切断要求を保存し、1 件目の終了が要求を実行して `isDisconnecting` を立てた後に 2 件目が終了する経路) が到達可能であるため、検出を `isDisconnecting` より前に置くと正しい入力で assertion が発火する。順序の理由はコードのコメントに書いた。`fatalError` ではなく `assertionFailure` + return にした (Release でプロセスを落とさない)
- `beginAsyncOperation` が拒否した経路で `endAsyncOperation` が呼ばれることはない。`requestDisconnect` は `.disconnectAcceptedWhileConnecting` を適用して残高を 0 にするのは「接続開始の初期ロックのみが残っている」場合だけであり、`createAndSendAnswer` 実行中の切断要求は残高を変えずに保存されるため、`endAsyncOperation` の残高が `isDisconnecting` の間も破綻しない
- `basicDisconnect` は `eventQueue.sync` の復帰後に `PeerChannel` が呼ぶ。`requestDisconnect` / `endAsyncOperation` / `prepareSignalingStart` / `finishSignalingStart` のいずれの経路でも、`basicDisconnect` を排他区間の内側では呼ばない。接続 callback 内から同期的に `disconnect()` へ再入しても、`ConnectionStateOwner` の queue へ再入しないため deadlock しない
- `PeerChannel` の入口は `beginConnectionStart()` / `startConnection(_:)` / `beginAsyncOperation()` / `endAsyncOperation()` / `disconnect(error:reason:)` の 5 つにした。`connect` / `disconnect` / `createAndSendAnswer` / `createAndSendUpdateAnswer` / `createAndSendReAnswer` / `createAndSendReAnswerOverDataChannel` / `handleSignalingOverWebSocket(_:)` の `.offer` / `finishConnecting` / `basicDisconnect` はこの入口だけを使う。`connect` の `onConnect = handler` は、旧 `Lock.nsLock` と同じく `beginConnectionStart()` が排他を解放した後に実行する
- `ConnectionStateOwner.init` の `snapshotStorage` は必須引数にした。既定値で内部生成すると、呼び出し元が読む storage と別の instance になり snapshot が無言で更新されなくなる (既定値を使う呼び出しは無い)

### 維持した不変条件

- `Lock.waitDisconnect` の遅延実行: 接続試行中の切断要求は `pendingDisconnect` に保存し、`asyncOperationCount == 0` になった時点 (および接続試行中の `== 1` で要求がある時点) で `basicDisconnect` へ渡す。猶予タイマー発動時の接続回復によるキャンセルと、保存済み要求の上書きも同じ
- `basicDisconnect` を lock (統合先の排他) 保持中に呼ばない
- `0151` の `connectHandlerLock` は統合対象外として維持した。(a) callback の 1 回保証 (`takeConnectHandler` の単一区間) (b) 利用者 callback を `connectHandlerLock` の区間外で呼ぶ (c) `connectHandlerLock` を保持したまま他の lock を取らない、の 3 条件は変更していない
- `webRTCConfigurationLock` は統合先へ吸収せず、別 lock として残した。保護対象が接続所有の WebRTC 設定の読み書きであり、接続ライフサイクルの状態とは異なる。値を読み書きする短い区間だけを保持する葉の lock で、統合先の排他 / `connectHandlerLock` / snapshot storage と入れ子にしない性質も維持する (`createAndSendAnswer` の read-modify-write は offer の受信ごとに 1 回だけで、`SignalingChannel` の直列 queue 上で実行されるため、現状の分割された読み出しと書き戻しのままで実害はない)
- `state` は owner queue へ `sync` させていない。`state` は統合先の排他を保持したまま判定 closure から呼ばれ、`nativeChannel` の写像と `connectHandlerLock` 経由の `onConnect` の有無だけで接続試行中を判定する
- `0175` の `createAnswer` の handler 契約は変更していない。handler が呼び出し元の `endAsyncOperation()` を担うことを、各 return 経路のコメントだけ `lock` から接続ライフサイクルの排他へ読み替えた
- 公開 API の変更はない (`PeerChannel` / `ConnectionStateOwner` は internal)

### lock 順序

- 許す向きは「統合先の排他 (`ConnectionStateOwner.eventQueue`) → `connectHandlerLock`」と「統合先の排他 → `ConnectionSnapshotStorage` の NSLock」の一方向だけにした
- 旧 `Lock.nsLock` を保持したまま `state` を読み、`state` が `onConnect` を読む経路 (旧 `waitDisconnect` / `startConnection` / `unlock` の 3 か所) が、`requestDisconnect` / `prepareSignalingStart` / `finishSignalingStart` / `endAsyncOperation` の 4 か所になっただけである。この向きの入れ子は避けられないため、`connectHandlerLock` を保持したまま統合先の排他を取る経路を作っていないことをコード読解で確認した (`onConnect` の getter / setter と `takeConnectHandler` は `connectHandlerLock` の区間内で `ConnectionStateOwner` の API を呼ばず、利用者 callback も区間外で呼ぶ)
- `webRTCConfigurationLock` は葉の lock とし、統合先の排他 / `connectHandlerLock` / storage と入れ子にしない。`ConnectionStateOwner` の各 `sync` 区間は `webRTCConfigurationLock` を取らない
- `eventQueue` 上で `eventQueue.sync` を再入する経路が無いことを確認した (`applyEvent` は queue 上の前提で呼び、`handle` と各 API の `sync` 区間から呼び出すのは `applyEvent` と snapshot の publish だけである)。統合前は `handle` の `sync` 区間内で reducer と publish を行っていたが、同じ処理を `applyEvent` へ切り出した
- `0177` が `nativeChannel` / `streams` / `offerEncodings` を lock 付き storage へ移す場合に生じる「統合先の排他 → storage」はこの向きのままであり、`state` が `nativeChannel` を読む経路も owner queue の `sync` 区間なので逆順を作らない

### テストの書き換え内容

- `SoraTests/PeerChannelConnectCompletionTests.swift`: `testDisconnectBeforeSignalingStartPreventsStart` と `testDisconnectDuringSignalingStartFinishesAfterOperation` の `peerChannel.lock.beginConnectionStart()` / `peerChannel.lock.startConnection { ... }` を、統合後の入口 `peerChannel.beginConnectionStart()` / `peerChannel.startConnection { ... }` へ書き換えた。検証するイベント順 (`XCTAssertFalse(didStartSignaling)` と `didFinishOperation`) は変えていない。`connectHandlerLock` のテスト (`testInvokeConnectHandlerConcurrentCallsRunsOnce` / `testConcurrentInvokeConnectHandlerAndStateReadRunsOnce` / `testInvokeConnectHandlerReentrantDisconnectRunsOnce`) は変更していない
- `SoraTests/StereoAudioOutputTests.swift`: `peerChannel.lock.lock()` / `peerChannel.lock.unlock()` を使っていた 4 件 (`testNativePeerConnectionCloseReleasesRequirement` と、識別子に `Unlock` を含んでいた 3 件。テスト名は検証内容を変えずに `testDelayedPeerChannelDisconnectKeepsRequirementUntilOperationEnds` / `testMediaChannelDeinitKeepsRequirementUntilOperationEnds` / `testMediaChannelDisconnectFinishesAfterOperationEnds` へ改名した。計 8 か所) を `peerChannel.beginAsyncOperation()` / `peerChannel.endAsyncOperation()` へ書き換えた。遅延切断が `endAsyncOperation` で実行されることと、AudioSession lease の解放順序の検証内容は変えていない。`## 変更対象` は `PeerChannelConnectCompletionTests` の 2 件だけを挙げていたが、`lock` を削除する以上この 4 件も書き換えが必要になるため対応した
- `SoraTests/ConnectionStateReducerTests.swift`: 追加した reducer の state / event を固定する 6 件を追加した (`testConnectionStartBeganEntersStartingInterval` / `testSignalingStartFinishedKeepsAsyncOperationCount` / `testSignalingStartCancelledReleasesAsyncOperationCount` / `testAsyncOperationBeganAndEnded` / `testDisconnectAcceptedKeepsOperationCount` / `testDisconnectAcceptedWhileConnectingReleasesAsyncOperationCount`)。モックやスタブは使わず、純粋関数へ実イベントを入力して検証する。`testDisconnectAcceptedKeepsOperationCount` は「受理時に進行中の非同期処理数が変わらないこと (完了を待たない)」を固定する形に直した (旧 `Lock` の不変条件ではなく、`isDisconnecting` 中の `endAsyncOperation` が残高を変えないという契約を表す)
- `SoraTests/ConnectionStateOwnerTests.swift` (新規): 移設した分岐を実 `ConnectionStateOwner` の同期 API だけで検証する 18 件を追加した。`prepareSignalingStart` の `.ignored` / `.start` / 取り消し・実行、`finishSignalingStart` の `isDisconnecting` 中の扱いと開始区間の無条件終了、`endAsyncOperation` の残高 0 到達と `isDisconnecting` 中の無視、`requestDisconnect` の遅延保存の上書き・接続試行中の強制解放・猶予タイマー由来の取り消しを対象にする。モックやスタブは使わず、猶予タイマーの判定 closure は `PeerChannel.shouldCancelDisconnectTimerBasedDisconnect` と同じ条件をテスト側で組み立てて渡す
- `SoraTests/ConnectionTimerLifecycleTests.swift`: `testTimeoutInvokesHandlerOnce` の「この PeerChannel の Lock は count == 0 のまま」「connect() の初期ロックで count == 1」というコメントを、`ConnectionStateOwner` と `asyncOperationCount` / `endAsyncOperation` の語彙へ直した。検証内容 (ConnectionTimer の timeout 配送が 1 回であること) は変えていない

### 実行した検証

検証環境は Xcode 26.6 / Swift 6.3.3 / iOS Simulator iPhone 17 Pro (OS 26.5) / libwebrtc m154.8037.1.2 である。

以下は最終リビジョン (指摘反映後) で取得した結果である。

- `swift format --in-place` の後、`make fmt-lint` は exit 0 (`build/0129-fmt-lint.log` は旧リビジョンのもの。最終リビジョンは実行のたびに exit 0)
- 全体テスト: `xcodebuild test` を直接実行すると `Could not resolve package dependencies` で exit 74 になり起動できない (SwiftPM の manifest cache `~/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/sora-ios-sdk.dia` が sandbox 外のため `Operation not permitted`。`build/0129-direct-test-verify.log`。`0151` と同じ制約で、PTY も使えない)。そのため `CFFIXED_USER_HOME` / `HOME` を `build/home` に向けた `xcodebuild build-for-testing -scheme Sora-Package -derivedDataPath build -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' SWIFT_VERSION=6 CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= PROVISIONING_PROFILE=` (`build/0129-final-build-for-testing.log`, TEST BUILD SUCCEEDED) の成果物を、iOS 26.5 の booted simulator (iPhone 17 Pro, UDID `643CF0FB-38D6-47D6-A145-EDD331B94DA1`) 上で `xcrun simctl spawn <udid> $(xcode-select -p)/Platforms/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/xctest <SoraTests.xctest>` として実行した (`SIMCTL_CHILD_DYLD_FRAMEWORK_PATH` に `build/Build/Products/Debug-iphonesimulator` を指定。`build/0129-final-tests.log`)。**433 件 / skip 30 / 失敗 0**。`## テスト方針` の回帰の正本 (`PeerChannelConnectCompletionTests` / `ConnectionTimerLifecycleTests` / `PeerChannelRedirectInvalidationTests` / `StereoAudioOutputTests`) はすべて成功し、接続 callback 内からの `disconnect()` 再入は `testInvokeConnectHandlerReentrantDisconnectRunsOnce` が deadlock せずに成功した。433 件は develop の 409 件 (`0151` の完了時点の実測) に本 issue で追加した reducer の 6 件と `ConnectionStateOwnerTests` の 18 件を加えた数である
- Thread Sanitizer: `-enableThreadSanitizer YES` で `build-for-testing` し (`build/0129-polish-tsan-build.log`, TEST BUILD SUCCEEDED)、`SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` に build が bundle へ複製した `libclang_rt.tsan_iossim_dynamic.dylib` (`build/Build/Products/Debug-iphonesimulator/SoraTests.xctest/Frameworks/`) を渡して実行した。`PeerChannelConnectCompletionTests` の 9 件は **検出 0** (`build/0129-polish-tsan-run.log`)、全 433 件 (skip 30) でも **`ThreadSanitizer` の行は 0** で失敗 0 (`build/0129-polish-tsan-all.log`)。TSan runtime が interposing 付きで load されたことは `DYLD_PRINT_LIBRARIES` (`SIMCTL_CHILD_DYLD_PRINT_LIBRARIES=1`) で `libclang_rt.tsan_iossim_dynamic.dylib` の load を確認した (`build/0129-polish-tsan-dyld.log`)
- `make build` / `make consumer-build SCHEME=ConsumerCore` / `make api-check-fresh` はすべて成功した。3 つとも sandbox では SwiftPM の manifest cache へ書けないため、`CFFIXED_USER_HOME` / `HOME` を `build/home` に向けて実行した (`build/0129-polish-make-build.log` / `build/0129-polish-consumer-build.log` / `build/0129-polish-api-check.log`。`The committed API baseline matches the current Sora module.`)
- `swiftlint lint --strict --cache-path build/swiftlint-cache` は 0 violations (`Found 0 violations, 0 serious in 64 files.`)
- 型検査 (`Sora/` を Swift 6 言語モードで `swiftc -typecheck`): 一次行の warning は 28 件 / error 0 件で、`#SendableClosureCaptures` は 11 件のまま増えていない (`build/0129-polish-typecheck.log`)

### 実 Sora での確認

`PeerChannelConnectCompletionE2ETests` は `SORA_SIGNALING_URL` が未設定のため skip される (skip 30 件に含まれる)。実 Sora と実 WebRTC を使う connect / cancel / redirect / disconnect / timeout の反復は、PR の `e2e-test.yml` で行う (本 issue の close 時点では未実施)。

### 残った懸念

- `ConnectionStateOwner` の同期 API は `eventQueue.sync` を使うため、serial queue へ再入する経路を作ると deadlock する。今回は再入経路が無いことを確認したが、今後 `ConnectionStateOwner` の state を参照する処理を `applyEvent` の内側へ足す場合は、`handle` / 各 API を呼ばないことを確認する必要がある
- `requestDisconnect` の判定 closure は、旧 `Lock.nsLock` を保持したまま `state` を読んでいた経路と同じく、統合先の排他を保持したまま `nativeChannel.connectionState` を読む。libwebrtc の内部 lock との順序は統合前と同じ向きであり、新たな逆順は作っていない
- `endAsyncOperation` の残高の破綻検出 (`assertionFailure`) は、`isDisconnecting` が真の間は働かない。旧 `Lock.unlock()` が `isDisconnecting` の場合に減算せず戻っていた挙動をそのまま維持したためである。`isDisconnecting` の間に残高が 0 のまま `endAsyncOperation` が呼ばれる経路は到達可能であり (残高 2 以上で切断要求を保存し、1 件目の終了が要求を実行して `isDisconnecting` を立てた後に 2 件目が終了する経路)、検出を `isDisconnecting` より前に置くと正しい入力で assertion が発火する。破綻検出の範囲を広げる場合は、この経路を正常系として除外する条件を先に設計する必要がある
