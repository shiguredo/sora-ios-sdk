# Sora target の `#SendableClosureCaptures` 警告のうち SDK 内部インスタンスを捕捉する 10 件を解消する

- Created: 2026-09-28
- Completed:
- Priority: Medium
- Branch: feature/refactor-remove-sora-internal-instance-captures
- Polished: 2026-09-29

## 目的

`Sora/` を Swift 6 言語モードで型検査したときに残る `#SendableClosureCaptures` 警告 11 件のうち、SDK 内部インスタンスを捕捉する 10 件を解消し、`0108` の Sora target warnings-as-errors ゲートを有効化できる状態へ前進させる。

`0108` のゲートは、本 issue が扱う 10 件と、`0115` が扱う `Sora/Utilities.swift` の `Utilities.Stopwatch` の 1 件が残る限り有効化できない。`0108` は `## 前提となる issue` で「SDK 内部インスタンスの capture 10 件を扱う issue は未起票」と書いており、本 issue がその未起票 issue にあたる。`0108` 側の担当記述の更新は `0108` 側の作業として行い、本 issue の変更対象には含めない。

`0173` (完了) は closure と外部 module の型の capture 14 件を用途限定 box と `Sendable` な値の写しで解消し、`## スコープ外` で本 issue が扱う 10 件を切り分けた。切り分けた理由は「SDK 内部の状態を用途限定 box の `@unchecked Sendable` で隠すのは `0108` の『未完了項目を隠してはならない』に反するため、捕捉対象の型の状態所有の扱いを決める別 issue とする」というものである。本 issue はその別 issue にあたり、box を追加すること自体を目的にせず、捕捉対象の型の状態所有 (排他区間・所有権) を整理することを目的にする。

## 優先度根拠

- 利用者に見える挙動と公開 API を変えない内部リファクタリングである
- 一方で `0108` のゲートを塞いでいる残り 2 要因の 1 つである (`Sora/Utilities.swift` の 1 件は `0115` の削除待ち)。放置すると `0108` の warnings-as-errors を有効化できない
- `PeerChannel` / `MediaChannel` の状態所有の整理を含み、`0151` / `0129` の結論に依存する経路があるため、`0173` と同じ Low ではなく Medium とする。`0129` の完了で待ちは解消したが、`0129` は接続ライフサイクルの排他を統合しただけで、`nativeChannel` / `streams` / `offerEncodings` の相互排他は残っている (「現状」)。この storage の設計は `0129` の結論を適用するだけでは決まらないため Medium を維持する

## カテゴリとスコープの確定

- 本 issue は `refactor` のままとする。ファイル名と `Branch:` (`feature/refactor-remove-sora-internal-instance-captures`) も変更しない。
- 公開型 `MediaChannel` / `ConnectionTask` に `Sendable` 準拠を足さない。したがって公開 API baseline (`TestConsumers/Swift6Consumer/ApiBaseline/`) の再生成と `TestConsumers/Swift6Consumer/NegativeChecks/core-sendable-capture.swift` の変更を本 issue に含めない。
  - `MediaChannel` は `handlers` (公開 `var`) / `internalHandlers` / `_handler` / `connectionCount` / `publisherCount` / `subscriberCount` などの保護されていない可変状態を持ち、`Sendable` を主張すると未整理の状態を `@unchecked Sendable` で隠すことになる (`0108`)。この整理は本 issue の 10 件の解消には不要であるため、`MediaChannel` は `Sendable` にしない。
  - `ConnectionTask` の可変状態 (`_internalState` / `_peerChannel`) は `stateLock` が全アクセスを保護しており、`@unchecked Sendable` の主張は「未完了項目を隠す」ではなく「既存の排他で状態所有が確定している」ことに基づけられる。ただし公開型への準拠追加は公開 API の追加であり、同じ変更に baseline の再生成と `SoraTests/SendableConformanceTests.swift` への `ConnectionTask` 本体の追加を伴う。本 issue は用途限定 box で捕捉を解消し、公開型の準拠は追加しない。
  - `PeerChannel` と `DataChannel` は internal のため、どちらの解消方針でも公開 API baseline に影響しない。
- 次のいずれかを選ぶ必要が実装中に判明した場合は、本 issue に混在させず、公開 API の追加として別 issue にする (本 issue の `refactor` と branch を汚さない)。
  - `ConnectionTask` に `Sendable` 準拠を足す場合: 同じ変更で `make api-baseline` による再生成と `SoraTests/SendableConformanceTests.swift` への追加が必要になる
  - `MediaChannel` に `Sendable` 準拠を足す場合: 先に `MediaChannel` の可変状態の整理が必要で、完了時に `make api-baseline` の再生成と `core-sendable-capture.swift` の負例 (対象を別の非 `Sendable` 型へ移すか負例自体を削除する) が必要になる。本 issue はこの整理を行わない
- 公開 API の closure 引数の型を `@Sendable` に変えない (`0110` / `0173` の方針を維持する)。`@preconcurrency` の追加、`Sora` target の default actor isolation の MainActor 化でも消さない。

## 現状

### 実測

2026-09-29 の Xcode 26.6 / Swift 6.3.3 で develop を `Sora/` の Swift 6 言語モードで型検査した実測は、一次行 (行頭が `Sora/<file>:<line>:<col>: warning:`) で warning 28 件 / error 0 件、うち `#SendableClosureCaptures` は 11 件である (型検査コマンドは「テスト方針」。log は `build/0177-typecheck-before.log`)。同じ環境で `0108` のゲート相当の flags (`-warnings-as-errors -Wwarning DeprecatedDeclaration`) を付けた型検査の一次行は error 11 件 / warning 0 件で、この 11 件は上記 11 件と一致する。`0129` の完了は `Sora/` の Swift source を変えたが、`#SendableClosureCaptures` の件数と捕捉対象は変わっていない。

file 別の内訳は `Sora/PeerChannel.swift` 6 件、`Sora/MediaChannel.swift` 3 件、`Sora/DataChannel.swift` 1 件、`Sora/Utilities.swift` 1 件である。本 issue が扱うのは `Sora/Utilities.swift` の 1 件を除く 10 件で、捕捉対象は次のとおり。位置はファイルパスとシンボル名で示す。

| # | ファイル | 捕捉対象 | 捕捉している closure と捕捉対象の使用 |
| --- | --- | --- | --- |
| 1 | `Sora/PeerChannel.swift` | `self` (`PeerChannel`) | `PeerChannel.initializeAudioInput()` が `RTCAudioSession.initializeInput(_:)` へ渡す完了 closure の内側で、`self.isAudioInputInitialized` に書き込む |
| 2 | `Sora/PeerChannel.swift` | `self` (`PeerChannel?`) | `PeerChannel.createAnswer(isSender:offer:constraints:initialOffer:mid:generation:handler:)` が `RTCPeerConnection.setRemoteDescription(_:completion:)` へ渡す完了 closure で `[weak self]` を取り、`self.dataChannelGeneration` / `self.nativeChannel` を読み、`self.initializeSenderStream(mid:)` / `self.updateSenderOfferEncodings()` を呼ぶ |
| 3 | `Sora/PeerChannel.swift` | `self` (`PeerChannel`) | 同じ `PeerChannel.createAnswer` の内側で `RTCPeerConnection.answer(for:completion:)` へ渡す完了 closure が、`self.dataChannelGeneration` / `self.nativeChannel` / `self.snapshot` を読む |
| 4 | `Sora/PeerChannel.swift` | `self` (`PeerChannel?`) | `PeerChannel.handleSignalingOverWebSocket(_:)` の `case .ping` が `RTCPeerConnection.statistics(_:)` へ渡す完了 closure で `[weak self]` を取り、`self.signalingChannel` を読んで `send` する |
| 5 | `Sora/PeerChannel.swift` | `self` (`PeerChannel?`) | `PeerChannel.scheduleWebSocketDisconnectIfNeeded()` が `DispatchQueue.global(qos: .background).asyncAfter(deadline:execute:)` へ渡す block で `[weak self]` を取り、`self.state` と `self.signalingChannel` を読む |
| 6 | `Sora/PeerChannel.swift` | `self` (`PeerChannel?`) | `PeerChannel.scheduleDisconnectTimerIfNeeded()` が `DispatchQueue.global(qos: .background).asyncAfter(deadline:execute:)` へ渡す block で `[weak self]` を取り、`self.disconnectTimerGeneration` / `self.handleConnectionEvent(_:)` / `self.state` / `self.disconnect(error:reason:)` を使う |
| 7 | `Sora/MediaChannel.swift` | `self` (`MediaChannel?`) | `MediaChannel.connect(webRTCConfiguration:onPrepared:handler:)` が `DispatchQueue.global().async(execute:)` へ渡す block で `[weak self]` を取り、`self?.basicConnect(connectionTask:)` を呼ぶ |
| 8 | `Sora/MediaChannel.swift` | `ConnectionTask` | 同じ `MediaChannel.connect` の block が、接続試行の `ConnectionTask` (局所名は `task`) を強参照で捕捉する |
| 9 | `Sora/MediaChannel.swift` | `self` (`MediaChannel?`) | `MediaChannel.getStats(handler:)` が `RTCPeerConnection.statistics(_:)` へ渡す完了 closure で `[weak self]` を取り、`self.state` と `self.peerChannel.nativeChannel` を読む |
| 10 | `Sora/DataChannel.swift` | `DataChannel` | `BasicDataChannelDelegate.dataChannel(_:didReceiveMessageWith:)` が `RTCPeerConnection.statistics(_:)` へ渡す完了 closure の内側で、`peerChannel.dataChannels` から取り出した `DataChannel` (局所名は `dc`) の `send(_:)` を呼ぶ |

警告が出るのは、WebRTC の Objective-C block と `DispatchQueue` の block が `@Sendable` closure として取り込まれるためである (`0173` の (A) / (B) 群と同じ原因)。

### 捕捉対象の型の状態所有

実コードでは次の状態にある。捕捉経路ごとの解消方針は「設計方針」に書く。

- `PeerChannel` (internal。`Sora/PeerChannel.swift`)
  - 接続状態フラグ 5 つ (`isRedirecting` / `webSocketDisconnectScheduled` / `disconnectTimerScheduled` / `dataChannelGeneration` / `disconnectTimerGeneration`) は `ConnectionStateOwner` が単一所有し、`ConnectionSnapshotStorage` の snapshot 経由で読む。`handleConnectionEvent(_:)` が更新経路である (`0100` の成果)。`ConnectionStateOwner` は `@unchecked Sendable` で、可変状態を serial `DispatchQueue` 上でのみ読み書きする。`ConnectionSnapshotStorage` は `NSLock` で `snapshot` の全アクセスを保護するが `Sendable` 宣言を持たない
  - `isAudioInputInitialized` は `var isAudioInputInitialized: Bool = false` として宣言され、読み (`PeerChannel.initializeAudioInput()` の先頭) と書き (`RTCAudioSession.initializeInput(_:)` の完了 closure) のいずれも lock 保護を持たない。所有者と保護区間が未定である
  - `nativeChannel` / `dataChannels` / `switchedToDataChannel` / `signalingOfferMessageDataChannels` / `rpcChannel` / `streams` / `offerEncodings` は lock 保護のない `var` である (`onConnect` は `0151` (完了 2026-09-28) で `connectHandlerLock` に閉じたため、着手時点の対象外である)。`ConnectionStateOwner` が接続ライフサイクルの排他として保護するのは `asyncOperationCount` / `isDisconnecting` / `isStartingConnection` / 遅延させる切断要求であり、これら `var` の相互排他ではない。この排他は非同期処理の生存数と切断の遅延を管理するため、進行中の非同期処理が無い状態 (`asyncOperationCount == 0`、または接続試行中の `asyncOperationCount == 1` から `onConnect != nil` を確認して強制的に `asyncOperationCount = 0` にした状態) で `basicDisconnect` を走らせることは保証するが、`state` getter のような任意スレッドからの読みと `createAndSendAnswer` の `nativeChannel` 書き込みを直列化しない。したがって表の 1 から 6 の経路には、`PeerChannel` の状態を `Sendable` と主張できる排他が無い
  - `webRTCConfiguration` は `webRTCConfigurationLock` 配下で読み書きする。`signalingChannel` と `snapshot` は `let` である。`snapshot` は `ConnectionConfigurationSnapshot` (checked `Sendable`) である
  - `PeerChannel.state` は `onConnect` の有無と `nativeChannel?.connectionState` の写像を合成する。`onConnect` を読む lock は `connectHandlerLock`、`nativeChannel` は lock 保護のない `var` である。表の 5 の `state != .closed` と表の 6 の `state == .disconnected` はどちらもこの合成を経由するため、closure 側で `nativeChannel?.connectionState` だけに置き換えられるかは表ごとに根拠が要る (「表の 5」「表の 6」)。状態の所有を整理したうえで、`state` の合成から `nativeChannel` の読みを外す
- `MediaChannel` (public。`Sora/MediaChannel.swift`)
  - `connectionLifecycleLock` (NSLock) が接続ライフサイクル (`state` / `currentConnectionTask` / `hasStartedConnection` / `disconnectPreparation` / `disconnectFinished` など) の遷移を直列化する。ただし `state` は `public private(set) var state: ConnectionState` であり、`isAvailable` や表の 9 の closure など lock の外から読む箇所がある
  - `handlers` (公開 `var`) / `internalHandlers` / `_handler` / `connectionCount` / `publisherCount` / `subscriberCount` は `connectionLifecycleLock` の外で読み書きされる。`connectionStartTime` は `connectionLifecycleLock` 配下で書くが、`connectionTime` は lock を取らずに読む。したがって `MediaChannel` 全体を `Sendable` と主張することはできない
  - 以上から、本 issue の `MediaChannel` の状態整理は `state` (表の 9) に限る。`connectionStartTime` と 3 つのカウント変数の排他は本 issue で扱わない (`## スコープ外`)
  - 表の 7 が呼ぶ `basicConnect(connectionTask:)` は、接続試行の有効性確認と `state` / `currentConnectionTask` の更新を `connectionLifecycleLock` 配下で行う。あわせて `peerChannel.internalHandlers` の closure 登録 (`let peerChannel` の参照経由) と `connectionTimer` の開始を行う
  - `WeakMediaChannelBox` は「MediaChannel 自体を `Sendable` とせず、終端処理だけを lifecycle lock 配下へ戻す」用途限定の box として既にある。`startDisconnectPreparation(error:)` の `Task { @Sendable in ... }` から `weakSelf.value?.completeDisconnectPreparation()` を呼ぶ経路だけで使い、doc コメントに用途を限定している
  - `MediaChannelGetStatsContext` は `0173` が追加した box で、handler と `RTCPeerConnection` だけを保持し、`MediaChannel` は保持しない
  - `MediaChannel` は公開型であり、`TestConsumers/Swift6Consumer/NegativeChecks/core-sendable-capture.swift` が「`Sendable` ではないこと」を負例として固定している。`Sendable` 準拠を足すと公開 API baseline (準拠の追加) の再生成とこの負例の変更が必要になる
- `ConnectionTask` (public。`Sora/Sora.swift`)
  - 可変状態は `stateLock` (NSLock) が保護する `_internalState` と `_peerChannel` だけである。`state` / `attach(peerChannel:)` / `markCanceled()` / `tryComplete()` / `complete()` / `cancel()` のいずれも `stateLock` を取り、`_internalState` と `_peerChannel` を触る箇所はこの 6 つに限られる (ソース全体を確認済み)。ロックを保持したまま callback を呼ばない設計は `0165` で入っている
  - 公開型 (`public final class ConnectionTask`) であり、公開 API baseline に `ConnectionTask` / `ConnectionTask.State` / `state` / `cancel()` が現れる。`Sendable` 準拠を足すと baseline の再生成が必要になる
  - `SoraTests/SendableConformanceTests.swift` は現在 `ConnectionTask.State` だけを対象にしており、`ConnectionTask` 本体の準拠は固定していない
- `DataChannel` (internal。`Sora/DataChannel.swift`)
  - `class DataChannel` の格納プロパティは `let native: RTCDataChannel` と `let delegate: BasicDataChannelDelegate` の 2 つだけで、可変状態を持たない。`compress` は `delegate.compress` (`let`) を返す computed property で、`send(_:)` は `delegate.compress` を読んで `native.sendData(_:)` を呼ぶ
  - 状態は `RTCDataChannel` (WebRTC) と `BasicDataChannelDelegate` (`weak var peerChannel` / `weak var mediaChannel` / `let compress` / `let generation`) が持つ。`BasicDataChannelDelegate` の 2 つの `weak var` への代入は `init` の 2 箇所だけで、他に書き換える箇所は無い (ソース全体を確認済み)
  - 内部型であり、公開 API baseline に現れない

## 設計方針

### box を使ってよい条件 (`0108` との整合)

`0108` は「未完了項目を `@unchecked Sendable` や `@preconcurrency` の追加で隠して manifest 更新だけを通してはならない」とし、その判定を「追加する型が (1) 可変状態を持たず `init` で確定した不変値だけを保持すること、(2) 変更前から同じ系統の非同期境界へ渡されており配送先・順序・呼び出し回数を変えないこと、(3) 保持するのが closure と、その closure が変更前から一緒に捕捉していた参照だけで、SDK 内部の参照型を新たに保持しないこと」の 3 条件で行うとしている。

本 issue は (1) と (2) をそのまま適用する。(3) の「SDK 内部の参照型を保持しないこと」は、参照型の状態所有が未整理であることを理由にした禁止である。したがって (3) は「保持する参照型に対する closure の状態アクセスが既存の排他に閉じる場合に限り保持を認める」と適用する。`0108` が要求する「どの経路のどの型をなぜ認めたか」の記録は、box の doc コメントと本 issue の「解決方法」に書く。したがって本 issue で参照保持 box を使ってよいのは、次をすべて満たす経路に限る。

- box 自身が可変状態を持たないこと。保持する参照は `init` で確定した `let`、または `init` でのみ代入する `weak var` であること (`weak var` は runtime が参照の load / store を原子的に扱い、代入後に値を書き換えない。既存の `WeakMediaChannelBox` がこの形である)
- box は配送先・順序・呼び出し回数を変えず、別系統の境界へ新たに渡さないこと
- box が保持する参照に対して closure が行う状態アクセス (closure が呼ぶメソッドが内部的に行うアクセスを含む) が、すべて box とは独立した既存または本 issue で確立する排他、もしくは `init` で確定した不変値に閉じること。どの排他がどの状態を守るかを box の doc コメントに書けること
- box 自身に `@unchecked Sendable` を付ける場合も、lock を保持したまま libwebrtc や利用者 handler を呼ばないこと (`0165` の教訓)。参照を排他配下で取り出し、その参照に対する呼び出しは排他を解放してから行う

この box の `@unchecked Sendable` は「box が使われる経路で closure が行う状態アクセスが安全である」という限定した主張であり、保持する参照型 (`PeerChannel` / `MediaChannel` / `ConnectionTask` / `DataChannel`) の全体が thread-safe であることは主張しない。この違いを box の doc コメントに書く。参照型全体の `Sendable` 準拠を足すかどうかは別の判断であり、本 issue では公開型に足さない (「カテゴリとスコープの確定」)。

この条件を満たせない経路では box を使わず、状態所有を整理するか、`Sendable` な値の写しで `self` を読まない形にする。`@unchecked Sendable` は box (入れ物) だけに付け、保持する参照型そのものを `Sendable` にはしない。状態の所有と同期の責務は既存の挙動の下での呼び出し側にあることを doc コメントに書く。

前例の `PeerChannelDisconnectCompletionContext` は `PeerChannel` を強参照で保持するが、これは切断処理が `ConnectionStateOwner.requestDisconnect` の経路へ戻す用途である。同じ判断を、接続ライフサイクルの排他や `stateLock` のような既存の排他が closure の状態アクセスを覆う経路へ適用する。

この判定基準を `0108` の記述に反映するかどうかは `0108` 側で判断する。本 issue は `0108` の変更対象を含めない。

### 表の 1 から 10 の解消方針

捕捉対象の型ごとに、排他が確定している状態と未確定の状態を分けて扱う。

#### `PeerChannel` の共通整理 (表の 1 から 6)

- `isAudioInputInitialized` の所有者を `ConnectionStateOwner` にする。`ConnectionLifecycleState` に `isAudioInputInitialized` を追加し、`ConnectionEvent` に書き込み用の case を追加する。接続試行状態と同じ扱いにして snapshot へは publish せず、読み取り用の同期 API を `stateForTesting()` と同じ位置付けで追加する。これで読み書きが単一所有者の直列 queue に閉じ、`PeerChannel` の lock 保護のない `var` は削除する
  - 完了 closure は `ConnectionStateOwner` (`@unchecked Sendable`) を捕捉し、その同期 API で読む。接続状態 owner の排他区間は同じ直列 queue へ再入できないため、owner が排他区間で呼ぶ closure (`shouldCancelDisconnectTimerBasedDisconnect` / `isConnectHandlerHeld`) からこの読み取り API を呼ばないこと。`isAudioInputInitialized` は切断判定から読まないため、この制約に触れない
  - snapshot へ publish する案は採らない。この値を別スレッドの同期 getter から観測する必要がないため、`ConnectionSnapshotStorage` の取得を増やさない (`ConnectionEffect.publishSnapshot` の対象を増やすと `ConnectionEvent` の追加時に publish の要否が曖昧になる)
  - `PeerChannel` に lock 保護のない同名の `var` は残さない (`## 完了条件`)。読みは接続状態 owner の同期 API だけを使う
- `nativeChannel` / `streams` / `offerEncodings` の読み書きを単一の排他へ移す。`ConnectionSnapshotStorage` と同じ「`NSLock` で保護した storage を 1 つ持ち、`@unchecked Sendable` を付ける」形の内部型を追加し、`PeerChannel` はその storage 経由で読み書きする。`nativeChannel` は `RTCPeerConnection` の参照を保持するため、storage の doc コメントには「参照の再代入を `NSLock` で直列化するだけで、`RTCPeerConnection` のオブジェクト状態の不変性は主張しない。参照の取り出しと、取り出した参照に対する `connectionState` などの呼び出しは別の区間で行う」と書く。`streams` と `offerEncodings` も同じ storage に置く。lock の順序は、`0129` が統合先に決めた接続状態 owner (`ConnectionStateOwner` の直列 queue) の排他 → `connectHandlerLock` と、接続状態 owner の排他 → storage の向きだけを許し、`connectHandlerLock` / storage を保持したまま接続状態 owner の排他を取らない (逆順を作らない)。`connectHandlerLock` と storage は入れ子にしない。`webRTCConfigurationLock` は値を読み書きする短い区間だけを保持する葉の lock であり、接続状態 owner の排他 / `connectHandlerLock` / storage のいずれとも入れ子にしない (`0129` は接続所有の WebRTC 設定を統合先へ吸収せず別 lock として残すと決めたため、storage を保持したまま `webRTCConfigurationLock` を取る形にもしない)

  `connectHandlerLock` は `onConnect` 専用に導入された lock であり、`0129` の統合対象外として維持する。本 issue は (a) callback の 1 回保証、(b) 利用者 callback を `connectHandlerLock` の区間外で呼ぶこと、(c) `connectHandlerLock` を保持したまま他の lock を取らないこと、の 3 条件を壊さない。`state` の合成が読む `onConnect` は `connectHandlerLock` の区間で 1 度だけ取り出し、`nativeChannel` は storage の区間で読む (両者を入れ子にしない)。この順序は、`0129` が `connectHandlerLock` を接続状態 owner の排他より内側に置いたことと矛盾しない (接続状態 owner → `connectHandlerLock` の向きを維持する)。
- `nativeChannel` / `streams` の読みを storage 経由にする箇所は、複数回読むと storage 区間の間で値が変わり得る。参照や配列を 1 度だけ取り出して使う形へ揃える。対象は次の 3 箇所である。
  - `basicDisconnect` の `if nativeChannel?.connectionState != .closed { nativeChannel?.close() }` は、参照を 1 度だけ取り出し、`connectionState` の読みと `close()` を storage の区間外で行う (`0165` の教訓)
  - redirect 経路の `for stream in streams { stream.terminate() }` と、これに続く空判定・件数ログ・`streams.removeAll()` は、storage から配列を 1 度取り出して使う
  - `basicDisconnect` の `for stream in streams { stream.terminate() }` と `streams.removeAll()` も同じ形にする
- `PeerChannel` の `nativeChannel` の書き込みは `createAndSendAnswer(offer:)` の 1 箇所だけである (ソース全体を確認済み)。読みは `state`、`createAnswer`、`initializeSenderStream`、`updateSenderOfferEncodings`、`basicDisconnect`、`handleSignalingOverWebSocket(_:)` の `.ping`、`MediaChannel.native` などにある。storage 化はこの書き込みと読みの排他を 1 つに揃える変更であり、書き込みの順序と配送は変えない
- 表の 2 から 6 は `PeerChannel` を捕捉するため、用途限定の参照保持 box を 1 つ追加して共用する。box は `weak var value: PeerChannel?` を持ち、`init` でのみ代入する。これにより `[weak self]` の「`self` が解放済みなら何もしない」挙動を維持する (`PeerChannelDisconnectCompletionContext` のように強参照にすると、`0175` が扱う `self` 解放時の handler 呼び出し経路が到達不能になり、`0007` が見送った判断を覆すことになる)
- box の doc コメントには、closure が呼ぶメソッドが到達する状態ごとにどの排他が守るかを列挙する。表の 3 / 4 / 5 が読む状態は本 issue の整理で閉じる。表の 2 / 6 は `disconnect` 経由で `onConnect` と切断経路の状態に到達する。`onConnect` の読み書きは `0151` で `connectHandlerLock` に閉じたため、box の doc コメントはその排他を根拠にする。切断経路の残りの状態は `0129` の結論を反映する (「前提となる issue」)
- `PeerChannel` 全体への `@unchecked Sendable` は主張しない。`dataChannels` / `rpcChannel` / `switchedToDataChannel` / `signalingOfferMessageDataChannels` / `dataChannelSignalingClose` / `connectedAtLeastOnce` / `sdp` / `internalHandlers` が未整理のまま残る (`onConnect` は `0151` で `connectHandlerLock` に閉じた)。これらを同じ排他へ入れる作業は接続ライフサイクルの reducer に踏み込むため、本 issue では扱わない

#### 表の 1

- 解消方針: 状態所有の整理 (上記)。完了 closure が捕捉するのは `ConnectionStateOwner` (`@unchecked Sendable`) だけにし、`self` を捕捉しない。読みは `initializeAudioInput()` の先頭で接続状態 owner の同期 API から行う。書きは owner の直列 queue 上の event で行う
- 完了 closure は `ConnectionStateOwner` を弱参照で捕捉する。強参照にすると、`RTCAudioSession` が完了 closure を保持し、その closure が owner を、owner が `PeerChannel` を保持する経路で `PeerChannel` が解放されなくなる。弱参照にすると、`PeerChannel` の解放後に完了 closure が走った場合は flag を立てない。これは変更前の `[weak self]` と同じ挙動である (`self` が解放済みなら何もしない)
- 書きの event は owner の直列 queue 上で適用する。完了 closure は WebRTC 側のスレッドから呼ばれるため、`handle(_:)` の同期 wait が直列 queue の実行を待つ。owner の排他区間から `initializeAudioInput()` や `RTCAudioSession` の完了 closure を呼ぶ経路は無いので、この待ちで再入しない
- 追加する `ConnectionLifecycleState` の field と書き込み用の event は、`isAudioInputInitialized` 単独で決まる接続状態フラグである。接続試行状態の不変条件 (`asyncOperationCount` / `isDisconnecting` / `isStartingConnection` の関係) を変えない
- `0151` (`onConnect` の排他) と `0129` (接続ライフサイクルの排他の統合先) の対象状態には触れない。`isAudioInputInitialized` は接続試行状態 (`asyncOperationCount` / `isDisconnecting` / `isStartingConnection`) や遅延させる切断要求とは別の接続状態フラグである。接続試行状態の不変条件を変えず、`ConnectionEffect.publishSnapshot` の対象にも加えない
- 利用者に見える挙動は変えない。フラグの意味は「`RTCAudioSession.initializeInput` が成功した」ことであり、成功後にだけ `true` にする現状の意味を維持する。check-then-act の原子性は現状も無いため、本 issue では 1 回保証を新たに設けない (必要なら別 issue とする)

#### 表の 2

- 解消方針: 状態所有の整理 + 参照保持 box。`nativeChannel` は追加する storage から読む。`dataChannelGeneration` は `ConnectionSnapshotStorage` から読む。`initializeSenderStream(mid:)` / `updateSenderOfferEncodings()` は `PeerChannel` のメソッドであるため、box の `value` 経由で呼ぶ。box の doc コメントには、`initializeSenderStream` が読む `nativeChannel` / `streams` / `offerEncodings` が storage の `NSLock` に、`snapshot` と `nativePeerChannelFactory` が `let` に、エラー経路の `disconnect` が `ConnectionStateOwner.requestDisconnect` の経路に閉じることを書く
- 参照保持 box は `weak var value: PeerChannel?` と、`init` で受け取った storage の `let` を持つ。完了 closure は box だけを捕捉する。box の `value` は、`guard let self else` と同じ 1 回保証の経路と `initializeSenderStream(mid:)` / `updateSenderOfferEncodings()` の呼び出しに使い、`nativeChannel` の読みは storage から行う。この分け方で、変更前の `self` が解放済みなら handler を呼ばない挙動と、`self` が nil の経路でも handler を 1 回呼ぶ `0175` の契約の両方を維持する
- 完了 closure が storage の参照を強参照で保持しても、storage は box を保持しないため、box と storage の間で循環参照にならない。storage を保持したまま `PeerChannel` が解放された場合は、変更前と同じく handler の 1 回保証の経路 (`0175` の `guard let self else` 節) に入る。この 2 点をコードのコメントに書く
- 前提: エラー経路の `disconnect` は `ConnectionStateOwner.requestDisconnect` から `context?.onConnect` を読み、`basicDisconnect` から `invokeConnectHandler` を呼ぶ。`onConnect` の読み書きは `0151` で `connectHandlerLock` に閉じ、切断経路の残りの状態は `0129` で接続状態 owner の排他へ統合された (どちらも完了済み)。したがって表の 2 の box の根拠は `connectHandlerLock` と接続状態 owner の排他である。この 2 つの排他を `PeerChannel` の追加 storage と入れ子にしない (「表の 1 から 6 の共通整理」の lock 順序)
- `0175` (完了 2026-09-28、`createAnswer` の `guard let self else` 節で handler を呼ぶ) と同じ closure を変更する。`0175` が確立した契約 (各 return 経路で高々 1 回。native の完了 block に委ねた経路を除き return する経路では必ず 1 回。native の完了が返らない場合は 0 回) を壊さない形にする。box の `value` が nil の経路でも handler が呼ばれることを維持する

#### 表の 3

- 解消方針: 参照保持 box + `Sendable` な値の写し。closure は box の `value` 経由で `dataChannelGeneration` (snapshot storage) / `nativeChannel` (追加する storage) / `snapshot` (`let` の `ConnectionConfigurationSnapshot`) を読む。外側の closure が `guard let` で束縛した `self` を内側の `answer(for:)` の closure が捕捉しないよう、内側の closure も box の `value` 経由にする。`guard let nativeChannel = self.nativeChannel` の再読は、世代照合で redirect が無いことを確認した後にだけ行われるため、同じ storage から読む形にしても「常に現在の `RTCPeerConnection` を使う」性質は変わらない。この等価性をコードのコメントに書く
- `createAnswer` の `constraints` / `offer` / `mid` / `generation` は既に `Sendable` な値または `let` である。`CreateAnswerHandlerBox` (`0173`) は変更しない

#### 表の 4

- 解消方針: 参照保持 box。`.ping` の完了 closure が読むのは `signalingChannel` (`let` の参照) だけで、`send` は `SignalingChannel` の `SignalingStateOwner` の直列 queue へ投入される。box の doc コメントに「`signalingChannel` は再代入されない `let` であり、その状態の読み書きは `SignalingStateOwner` の直列 queue が所有する。`SignalingChannel.internalHandlers` は `PeerChannel.init` と `MediaChannel.connect` で接続開始前に設定され、この closure は読まない」と書く
- 世代や `state` を読まないため、`0151` / `0129` に依存しない

#### 表の 5

- 解消方針: 状態所有の整理 + 参照保持 box。closure が判定に使う `self.state` は `onConnect` と `nativeChannel?.connectionState` を合成する getter である。`state != .closed` と「storage の `nativeChannel?.connectionState != .closed`」は、次の 1 つの場合を除いて一致する
  - `onConnect != nil` かつ `nativeChannel == nil` の場合、`state` は `.connecting`、`nativeChannel?.connectionState` は `nil` であり、`nil` は `.closed` ではないため、どちらも「閉じていない」で一致する
  - 一致しなくなるのは、`basicDisconnect` が `nativeChannel` を close して `connectionState` が `.closed` になった後、`storedOnConnect` がまだ保持されている間に closure が `state` を読む場合である。この場合に限り、`state` は `nativeChannel` の `.closed` を `.connecting` または `.new` として返し、閉じた channel への WebSocket 切断が起き得る。この切断は `webSocketDisconnectScheduled` の 1 回保証と、閉じた channel への切断が無害であること (`basicDisconnect` のコメント) で抑止される
  - この判断をコードのコメントに書く
- `nativeChannel` は storage 配下で参照を取り出し、`connectionState` の読みは `NSLock` を解放してから行う (`0165` の教訓)

#### 表の 6

- 解消方針: 状態所有の整理 + 参照保持 box。`disconnectTimerGeneration` は `ConnectionSnapshotStorage`、`handleConnectionEvent(_:)` は `ConnectionStateOwner`、`disconnect(error:reason:)` は `ConnectionStateOwner.requestDisconnect` の経路である。`state == .disconnected` は `nativeChannel?.connectionState == .disconnected` と等価である。`.disconnected` は `onConnect` の上書き (`.new` → `.connecting`) の対象外であり、`nativeChannel == nil` のとき `state` は `.new` / `.connecting` のどちらかで `.disconnected` にならないため、`nativeChannel?.connectionState == nil` (`.disconnected` 以外) と一致する
- 前提: `disconnect` は `rpcChannel` / `dataChannelSignalingClose` / `connectedAtLeastOnce` / `streams` / `nativeChannel` / `onConnect` / `internalHandlers` に到達する。`onConnect` は `0151` で `connectHandlerLock` に閉じ、切断経路の残りの状態は `0129` で接続状態 owner の排他へ統合された (どちらも完了済み)。したがって表の 6 の box の根拠は `connectHandlerLock` と接続状態 owner の排他であり、`nativeChannel` と `streams` は本 issue の追加 storage である
- `disconnect` の呼び出し回数・順序・配送先を変えないこと。接続ライフサイクルの排他の遅延実行セマンティクスを維持する

#### 表の 7

- 解消方針: 参照保持 box (`WeakMediaChannelBox` の用途拡張)。`MediaChannel.connect` の `DispatchQueue.global().async` の block は `basicConnect(connectionTask:)` を呼ぶだけである。`basicConnect` が直接触る `MediaChannel` の状態は、`let peerChannel` の参照、`connectionLifecycleLock` で保護する区間で更新する `state` / `currentConnectionTask` / `connectionStartTime`、`connectionTimer`、および `peerChannel.internalHandlers` への closure 登録である (`connectionStartTime` の読みの排他は本 issue では扱わない。`## スコープ外`)。既存の `WeakMediaChannelBox` の doc コメントの用途を「終端処理と接続開始を lifecycle lock 配下へ戻す」へ広げ、この box の `value` 経由で `basicConnect` を呼ぶ
- `peerChannel.internalHandlers` の各 closure property は `connect` と `basicConnect` で 1 回ずつ設定され、同じ property を別スレッドから同時に読み書きする経路は無い。この前提 (同じ property への再代入が無いこと) を doc コメントに書く
- `MediaChannel` 自体を `Sendable` としないこと、`basicConnect` が呼ぶ `peerChannel.connect` の配送先・順序・呼び出し回数を変えないことを doc コメントに書く
- `ConnectionTask` (表の 8) を closure が捕捉しない形にするため、`basicConnect` の呼び出しから `task` の引数を外さない (引数を外すと `connectionLifecycleLock` の外で `currentConnectionTask` を読み直すことになり、切断と競合したときの挙動が変わる)。`task` は表の 8 の box が保持する

#### 表の 8

- 解消方針: 参照保持 box。`ConnectionTask` を保持する用途限定 box を追加し、`DispatchQueue.global().async` の block は box 経由で `task` を参照する。`stateLock` が `_internalState` と `_peerChannel` の全アクセス (6 つのメソッド) を保護することを doc コメントに書く
- `ConnectionTask` 自身に `Sendable` 準拠を足さない (「カテゴリとスコープの確定」)。足す場合は別 issue とする

#### 表の 9

- 解消方針: 状態所有の整理 + box の拡張。`MediaChannel.state` の読みを、`connectionLifecycleLock` と同じ順序でだけ入れ子にする単一の lock 付き storage に移し、`state` はその storage を読む読み取り専用 property にする (`connectionLifecycleLock` → state storage の順のみを許し、逆順を作らない)。`state` を書く箇所は `connectionLifecycleLock` を保持しているので、書く区間から storage の lock を取る順序も同じ向きに揃える。`peerChannel.nativeChannel` は `PeerChannel` の追加 storage から読む。`MediaChannelGetStatsContext` に state storage と `PeerChannel` の storage の参照を追加し、closure は `context` 経由で `state` と `nativeChannel` を読む (`self` を捕捉しない)。同一性判定 `currentPeerConnection === context.peerConnection` は意味を変えない
- `state` の公開表現 (読み取り専用 property) を変えず、`make api-check-fresh` と `git diff --exit-code -- TestConsumers/Swift6Consumer/ApiBaseline/` で baseline に差分が出ないことを確認する。差分が出た場合は、この storage 化を別 issue に分離し、本 issue では `state` の読みを別の排他に閉じる方式へ切り替える
- `0176` が追加を予定する `setConnectionStateForTesting(_:)` は `connectionLifecycleLock` 配下で `state` を書くため、本 issue の storage 化の後に実装する場合は storage 経由の書き込みに合わせる。本 issue は `0176` 側の seam を追加しない
- どの storage が何を守るかを `MediaChannelGetStatsContext` の doc コメントに書く

#### 表の 10

- 解消方針: 参照保持 box。`DataChannel` を保持する用途限定 box を追加し、`statistics` の完了 closure は box 経由で `dc.send(_:)` を呼ぶ。`DataChannel` の格納プロパティが `let` の 2 つだけで、`BasicDataChannelDelegate` の `weak var` への代入が `init` の 2 箇所だけであることを doc コメントに書く
- `DataChannel` 自身に `@unchecked Sendable` を足す案は採らない。box の方が主張の範囲を 1 経路に限定できるためである (`DataChannel` は internal のためどちらでも公開 API への影響は無い)

### コメントに書くこと

追加・変更する box・storage・`@unchecked Sendable` と、`PeerChannel` の追加 storage の doc コメントには、次を日本語で書く。ソースコードに issue 番号は書かない。

- `Sendable` を主張できる根拠 (既存または本 issue で確立する排他、または `init` で確定した不変値であること) と、どの排他がどの状態を守るか
- 新しい並行境界を増やしていないこと (配送先・順序・呼び出し回数を変えないこと)
- 捕捉対象の状態の所有と同期が誰の責務か
- 参照保持 box では、保持する参照が変更前の closure が捕捉していた参照と同一であること
- コメントの粒度の前例は `MediaChannelGetStatsContext` / `CreateAnswerHandlerBox` (`0173` が追加)、参照だけを保持する box の前例は `WeakMediaChannelBox` / `PeerChannelDisconnectCompletionContext` である

### `CHANGES.md`

`## develop` の主リストに、`0173` / `0174` と同じ粒度で次の `[UPDATE]` エントリを追加する (インデントはこの節の入れ子のためのもので、`CHANGES.md` へは外して追記する)。

```
- [UPDATE] `Sora` target の SDK 内部インスタンスを捕捉する `#SendableClosureCaptures` 警告 10 件を解消する
  - `PeerChannel` の `isAudioInputInitialized` と `nativeChannel` / `streams` / `offerEncodings` の状態所有を整理し、`MediaChannel` / `DataChannel` の捕捉は用途限定の参照保持 box で解消する
  - 公開 API と利用者の挙動の変更はない
  - @t-miya
```

## 前提となる issue

本 issue が着手条件にしていた `0151` (2026-09-28 完了) / `0129` (2026-09-29 完了) / `0175` (2026-09-28 完了) はすべて develop に入っており、着手を妨げる前提は残っていない。`0129` は `PeerChannel.Lock` を `ConnectionStateOwner` の直列 queue へ統合し、統合先の同期 API は `beginConnectionStart` / `prepareSignalingStart` / `finishSignalingStart` / `beginAsyncOperation` / `endAsyncOperation` / `requestDisconnect`、接続試行状態は `ConnectionLifecycleState` の `asyncOperationCount` / `isDisconnecting` / `isStartingConnection` と遅延させる切断要求である。本 issue はこの API 名と排他を前提に書く。`0176` は `MediaChannel.getStats` 側が本 issue の完了待ちであり、同一性判定の回帰テストは `0176` が追加するものを正本として重複させない (「テスト方針」)。

- `0173` (完了 2026-09-28): 切り分けの根拠。`## スコープ外` が本 issue の 10 件 (C 群) を切り分け、用途限定 box で包まない理由と、`MediaChannel` / `ConnectionTask` が公開型のため `Sendable` 準拠の是非も含めて判断することを書いている。本 issue はこの切り分けを引き継ぐ
- `0108` (open): Sora target の warnings-as-errors 化。本 issue の完了が `0108` の前提であり、その逆ではない。`0108` は本 issue を未起票として扱っているため、本 issue の起票後に `0108` 側の記述を更新する必要がある。この更新は `0108` 側の作業として行い、本 issue の変更対象には含めない
- `0115` (pending、`issues/pending/0115-remove-stopwatch.md`): `Utilities.Stopwatch` を削除する。`Sora/Utilities.swift` の 1 件はこの削除で消える。`0115` は非推奨化 release と次期 major version を前提にするため本 issue の期間内に完了するとは限らない。本 issue は `0115` を待たず、`0115` の変更対象も書き換えない。`0115` が先に完了した場合は、完了条件の「残る 1 件」を 0 件として読み替える
- `0151` (完了 2026-09-28): `PeerChannel.onConnect` のデータ競合。`onConnect` の読み書きは専用の `connectHandlerLock` に閉じた (接続試行中の判定 (`state` / `ConnectionStateOwner.requestDisconnect`) の読みも同じ排他に入る)。表の 2 と 6 の box の根拠は、`disconnect` 経由で `onConnect` を読む経路 (`ConnectionStateOwner.requestDisconnect` の `context?.onConnect` の読みと、`basicDisconnect` からの `invokeConnectHandler` の呼び出し) がこの排他に閉じることに依存する。`connectHandlerLock` を `0129` の統合対象外として維持し `0129` が壊してはならない 3 条件は「設計方針」に書く。本 issue は `0151` の変更対象 (`onConnect` の排他) を書き換えず、その結論に従って box の doc コメントを書く
- `0129` (完了 2026-09-29): `PeerChannel.Lock` を接続状態 reducer へ統合する。統合先は `ConnectionStateOwner` の直列 queue に決まり、`Lock` の状態 (進行中の非同期処理数 / `isDisconnecting` / `isStartingConnection` / 遅延させる切断要求) は `ConnectionLifecycleState` と `ConnectionStateOwner` の private な保持へ、`Lock` の各 API は `ConnectionStateOwner` の `beginConnectionStart` / `prepareSignalingStart` / `finishSignalingStart` / `beginAsyncOperation` / `endAsyncOperation` / `requestDisconnect` へ移った。`webRTCConfigurationLock` は吸収されず葉の lock として残る。表の 2 と 6 が到達する切断経路の排他は接続状態 owner の排他になったため、本 issue は「設計方針」の lock 順序に従い、box の doc コメントをこの結論に合わせ、追加する storage を接続状態 owner の排他とも `webRTCConfigurationLock` とも入れ子にしない
- `0175` (完了 2026-09-28): `createAnswer` の `guard let self else` 節でも handler を呼ぶ。表の 2 と同じ closure を変更するため、`0175` が確立した契約 (各 return 経路で高々 1 回。native の完了 block に委ねた経路を除き return する経路では必ず 1 回。native の完了が返らない場合は 0 回) を壊さない形にする。本 issue は `0175` の修正内容を先取りしない
- `0176` (open): `0173` の参照保持 box の回帰テスト。`createClientOfferSDP` 側は完了済みで、`MediaChannel.getStats` 側 (`setConnectionStateForTesting(_:)` と同一性判定の回帰テスト) は本 issue の完了後に着手する。本 issue は `MediaChannel.getStats` の closure を書き換えるが、`0176` の seam とテストは追加せず、`0176` が本 issue の完了後の実装へ向けて設計できる状態にする (「テスト方針」)

## 変更対象

- `Sora/ConnectionLifecycle.swift`: `ConnectionLifecycleState` に `isAudioInputInitialized` を追加し、`ConnectionEvent` に `isAudioInputInitialized` の書き込み用の case を追加する
- `Sora/PeerChannel.swift`: 表の 1 から 6。`PeerChannel` の参照保持 box (表の 2 から 6 で共用)、`nativeChannel` / `streams` / `offerEncodings` の lock 付き storage、`ConnectionStateOwner` の `isAudioInputInitialized` 読み取り API を呼ぶ `initializeAudioInput()`、`createAnswer` / `handleSignalingOverWebSocket(_:)` の `.ping` / `scheduleWebSocketDisconnectIfNeeded()` / `scheduleDisconnectTimerIfNeeded()` の変更。`basicDisconnect` と redirect 経路の `nativeChannel` / `streams` の読みを 1 度だけ取り出す形へ揃える
- `Sora/MediaChannel.swift`: 表の 7 から 9 (`MediaChannel.connect` の `self` と `ConnectionTask`、`MediaChannel.getStats` の `self`)。`WeakMediaChannelBox` の用途拡張、`ConnectionTask` 用の box、`state` の lock 付き storage、`MediaChannelGetStatsContext` の拡張
- `Sora/DataChannel.swift`: 表の 10 (`DataChannel` 用の box)
- `SoraTests/`: 追加する box / storage の回帰テスト (「テスト方針」)。特に `SoraTests/ConnectionStateOwnerTests.swift` への `isAudioInputInitialized` の状態遷移の追加
- `CHANGES.md`: `## develop` の主リストへの `[UPDATE]` エントリの追記 (担当者行 `@t-miya` を含む)
- `TestConsumers/Swift6Consumer/ApiBaseline/` / `TestConsumers/Swift6Consumer/NegativeChecks/core-sendable-capture.swift`: 変更しない (差分が空であることを確認する)

## テスト方針

モックやスタブは使用しない。検証は Xcode 26.6 と `iphoneos26.5` の環境で行い、版数は着手時点の `Makefile` の `API_XCODE` / `XCODE_SDK` に読み替える。

- 実装前後の型検査 log を比較する。`build/` は `.gitignore` の対象で fresh な checkout には無いため、log を取る前に `mkdir -p build` を実行し、`-F` には `swift package resolve` が作る xcframework の slice ディレクトリを指定する。

  ```
  swiftc -typecheck -swift-version 6 -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -target arm64-apple-ios14.0-simulator \
    -F .build/artifacts/sora-ios-sdk/WebRTC/WebRTC.xcframework/ios-arm64-simulator \
    -module-cache-path build/module-cache $(find Sora -name '*.swift') 2>&1 | tee build/0177-typecheck-after.log
  ```

- 実装後の log で次を確認する。診断は `^Sora/[^:]+:[0-9]+:[0-9]+: warning:` で始まる一次行だけを数える。
  - `#SendableClosureCaptures` が `Sora/Utilities.swift` の `Utilities.Stopwatch` の 1 件だけ (`0115` 完了済みなら 0 件)
  - 一次行の総数が、実装前の log から消えた `#SendableClosureCaptures` の件数だけ減っている (`0115` 未完了なら 28 → 18、完了済みなら 28 → 17 を目安に、実装時に同じ条件で取り直した値で判定する。実装前の値は「現状」の実測に対応する)
  - `#no-usage` などの新しい警告が増えていない (上の総数で検出する)
- `0108` のゲート相当の flags を付けた型検査で error が 1 件 (`0115` 完了後は 0 件) だけであること。

  ```
  swiftc -typecheck -disable-batch-mode -continue-building-after-errors \
    -swift-version 6 -warnings-as-errors -Wwarning DeprecatedDeclaration \
    -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -target arm64-apple-ios14.0-simulator \
    -F .build/artifacts/sora-ios-sdk/WebRTC/WebRTC.xcframework/ios-arm64-simulator \
    -module-cache-path build/module-cache $(find Sora -name '*.swift') 2>&1 | tee build/0177-gate-after.log
  ```

- 表の 10 件それぞれについて、対象の closure の `capture of` が該当する file とシンボルから消えていることを型検査 log で示す。`grep -cE "^Sora/[^:]+:[0-9]+:[0-9]+: warning: .*SendableClosureCaptures" build/0177-typecheck-after.log` が 1 (`0115` 完了済みなら 0) であり、残る 1 件が `Sora/Utilities.swift` の `Utilities.Stopwatch` であること。
- `SoraTests` を実行し失敗 0 件であること。表の 10 件は closure の捕捉対象を置き換える変更であり、いずれも既存テストの観測対象を含む。本 issue が回帰テストで固定するのは次の 3 つに限り、残りは型検査と `SoraTests` 全体を回帰の正本とする。
  - `ConnectionStateOwner` の新しい event で `isAudioInputInitialized` の状態が更新されること (`RTCAudioSession.initializeInput` の呼び出し回数は実物では観測できないため、モックを使わずに reducer の状態遷移を回帰の正本にする)。既存の `SoraTests/ConnectionStateOwnerTests.swift` に追加する
  - `MediaChannel.getStats` の完了 block の同一性判定 (`currentPeerConnection === context.peerConnection`) が redirect 後に失敗すること。この経路のテストは `0176` が追加するものを正本とし、本 issue では追加しない (`0176` の完了後に実装される `setConnectionStateForTesting(_:)` と合わせて成立する)
  - `DataChannel` の box 経由の `send` が呼ばれること (実 `RTCDataChannel` を使う)
- 上の 3 つ以外の経路は、型検査 log で捕捉の消失を示し、`SoraTests` 全体の失敗 0 件を回帰の正本とする。単体 harness を構成できない場合は、その理由と代替の検証内容を「解決方法」に記録する。
- `make build` が成功すること。Thread Sanitizer は `0119` に従い完了条件に含めない。
- `make consumer-build SCHEME=ConsumerCore` と `make api-check-fresh` が成功すること。`git diff --exit-code -- TestConsumers/Swift6Consumer/ApiBaseline/` が空であること。差分が出た場合は `make api-baseline` を実行せず、公開 API の変更として別 issue に分離する (「設計方針」の表の 9)。
- `make consumer-check-negative` が成功すること (負例は変更しない)。
- `make fmt-lint` と `make lint` が成功すること。

## 完了条件

- `Sora/` の Swift 6 言語モードの型検査で `#SendableClosureCaptures` が、表の 10 件が消えて `Sora/Utilities.swift` の `Utilities.Stopwatch` の 1 件だけになること (`0115` が先に完了している場合は 0 件)。`0108` のゲート相当の flags を付けた型検査の error が 1 件 (または 0 件) だけであること。一次行の総数が、消えた `#SendableClosureCaptures` の件数だけ減っていること。
- 表の 10 件のそれぞれについて、`Sendable` を主張する根拠 (既存または本 issue で確立する排他、または `init` で確定した不変値であること) と、新しい並行境界を増やしていないことが日本語コメントで書かれ、コメントに issue 番号が書かれていないこと。参照だけを保持する box を使った経路には、捕捉対象の状態アクセスが既存の排他または不変性で守られている根拠が書かれていること。
- 追加した box / storage の `@unchecked Sendable` の根拠が doc コメントに書かれ、`@unchecked Sendable` が入れ物だけに付き、保持する参照型そのものを `Sendable` にしていないこと。`git diff -U0 -- Sora/ | grep -E '^\+.*@unchecked Sendable'` を読み、追加が box / storage の宣言行だけであること。
- `git grep -n 'final class ConnectionTask\|final class MediaChannel' -- Sora/` の結果に `Sendable` が付いていないこと。`git grep -n '@preconcurrency import' -- Sora/` が空であること。
- 公開 API のシグネチャと利用者に見える挙動を変えていないこと。`@Sendable` 化、`@preconcurrency` の追加、default actor isolation の MainActor 化で警告を消していないこと。`git diff --exit-code -- TestConsumers/Swift6Consumer/ApiBaseline/` と `git diff --exit-code -- TestConsumers/Swift6Consumer/NegativeChecks/` が空であること。
- `make build`、`SoraTests` (失敗 0)、`make consumer-build SCHEME=ConsumerCore`、`make api-check-fresh`、`make consumer-check-negative`、`make fmt-lint`、`make lint` が成功すること。
- 「テスト方針」に挙げた回帰テストがあること。構成できなかった経路の理由と代替の検証内容が「解決方法」に書かれていること。
- `PeerChannel` の `isAudioInputInitialized` が `ConnectionStateOwner` の単一所有になり、`PeerChannel` に lock 保護のない同名の `var` が残っていないこと。`git grep -n 'isAudioInputInitialized' -- Sora/` の結果が `ConnectionLifecycleState` / `ConnectionEvent` の宣言と `ConnectionStateOwner` の読み取り API、および `PeerChannel` のその API 経由の読みだけであること。
- `CHANGES.md` の `## develop` の主リストに「設計方針」に書いた文面の `[UPDATE]` エントリが担当者行付きで追加されていること。

## スコープ外

- `Sora/Utilities.swift` の `Utilities.Stopwatch` の 1 件。`0115` の削除で消える。本 issue は `0115` を待たず、`0115` の変更対象も書き換えない。
- `#DeprecatedDeclaration` 警告。`0108` の `.treatWarning("DeprecatedDeclaration", as: .warning)` で warning のまま残す (`0138` が対象外とする iOS SDK 由来の deprecation 警告を error にしないため)。
- test target の warnings-as-errors ゲート (`0171`)。
- `PeerChannel.onConnect` のデータ競合そのもの (`0151`) と接続ライフサイクルの排他の統合そのもの (`0129`)。本 issue は表の 2 と 6 の box の根拠として両者の結論を前提にするだけで、両 issue の変更対象を書き換えない。
- `PeerChannel` 全体への `@unchecked Sendable` の付与。`onConnect` / `dataChannels` / `rpcChannel` / `switchedToDataChannel` / `signalingOfferMessageDataChannels` / `dataChannelSignalingClose` / `connectedAtLeastOnce` / `sdp` / `internalHandlers` の整理が必要になる。表の 10 件の解消には不要なため、本 issue では行わない。必要になった場合は別 issue とする。
- `ConnectionTask` / `MediaChannel` への `Sendable` 準拠の追加。公開 API の追加であり、本 issue (`refactor`) とは別 issue とする。
- `issues/0108-update-swiftpm-language-mode.md` の担当記述の更新。本 issue の起票後に `0108` 側の作業として行う。
- `@preconcurrency` の追加と default actor isolation の変更で警告を消すこと (本 issue では行わない)。
- `MediaChannel.handlers` / `internalHandlers` / `connectionStartTime` / `connectionCount` / `publisherCount` / `subscriberCount` など、表の 10 件の捕捉対象以外の未整理な可変状態。`state` 以外の `MediaChannel` の状態所有は本 issue で整理しない。

## 解決方法
