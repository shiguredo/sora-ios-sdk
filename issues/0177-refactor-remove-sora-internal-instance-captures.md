# Sora target の `#SendableClosureCaptures` 警告のうち SDK 内部インスタンスを捕捉する 10 件を解消する

- Created: 2026-09-28
- Completed:
- Branch: feature/refactor-remove-sora-internal-instance-captures
- Polished:

## 目的

`Sora/` を Swift 6 言語モードで型検査したときに残る `#SendableClosureCaptures` 警告 11 件のうち、SDK 内部インスタンスを捕捉する 10 件を解消し、`0108` の Sora target warnings-as-errors ゲートを有効化できる状態へ前進させる。

`0108` のゲートは、本 issue が扱う 10 件と、`0115` が扱う `Sora/Utilities.swift` の `Utilities.Stopwatch` の 1 件が残る限り有効化できない。`0108` は `## 前提となる issue` で「SDK 内部インスタンスの capture 10 件を扱う issue は未起票」と書いており、本 issue がその未起票 issue にあたる。

`0173` (完了) は closure と外部 module の型の capture 14 件を用途限定 box と `Sendable` な値の写しで解消し、`## スコープ外` で本 issue が扱う 10 件を切り分けた。切り分けた理由は「SDK 内部の状態を用途限定 box の `@unchecked Sendable` で隠すのは `0108` の『未完了項目を隠してはならない』に反するため、捕捉対象の型の状態所有の扱いを決める別 issue とする」というものである。本 issue はその別 issue にあたり、box を追加すること自体を目的にせず、捕捉対象の型の状態所有 (排他区間・所有権) を整理することを目的にする。

## 現状

2026-09-28 の Xcode 26.6 / Swift 6.3.3 で develop を `Sora/` の Swift 6 言語モードで型検査した実測は、warning 28 件 / error 0 件で、うち `#SendableClosureCaptures` は 11 件である (型検査コマンドは「テスト方針」)。`0174` の完了後も `Sora/` の Swift source は変わっていないため、この 11 件が現在の develop の値である (2026-09-28 に再計測して確認済み)。

file 別の内訳は `Sora/PeerChannel.swift` 6 件、`Sora/MediaChannel.swift` 3 件、`Sora/DataChannel.swift` 1 件、`Sora/Utilities.swift` 1 件である。本 issue が扱うのは `Sora/Utilities.swift` の 1 件を除く 10 件で、捕捉対象は次のとおり。位置はファイルパスとシンボル名で示す。

| # | ファイル | 捕捉対象 | 捕捉している closure と捕捉対象の使用 |
| --- | --- | --- | --- |
| 1 | `Sora/PeerChannel.swift` | `self` (`PeerChannel`) | `PeerChannel.initializeAudioInput()` が `RTCAudioSession.initializeInput(_:)` へ渡す完了 closure の内側で、`self.isAudioInputInitialized` に書き込む |
| 2 | `Sora/PeerChannel.swift` | `self` (`PeerChannel?`) | `PeerChannel.createAnswer(isSender:offer:constraints:initialOffer:mid:generation:handler:)` が `RTCPeerConnection.setRemoteDescription(_:completion:)` へ渡す完了 closure で `[weak self]` を取り、`self.dataChannelGeneration` / `self.nativeChannel` を読み、`self.initializeSenderStream(mid:)` / `self.updateSenderOfferEncodings()` を呼ぶ |
| 3 | `Sora/PeerChannel.swift` | `self` (`PeerChannel`) | 同じ `PeerChannel.createAnswer` の内側で `RTCPeerConnection.answer(for:completion:)` へ渡す完了 closure が、`self.dataChannelGeneration` / `self.nativeChannel` を読む |
| 4 | `Sora/PeerChannel.swift` | `self` (`PeerChannel?`) | `PeerChannel.handleSignalingOverWebSocket(_:)` の `case .ping` が `RTCPeerConnection.statistics(_:)` へ渡す完了 closure で `[weak self]` を取り、`self.signalingChannel` を読んで `send` する |
| 5 | `Sora/PeerChannel.swift` | `self` (`PeerChannel?`) | `PeerChannel.scheduleWebSocketDisconnectIfNeeded()` が `DispatchQueue.global(qos: .background).asyncAfter(deadline:execute:)` へ渡す block で `[weak self]` を取り、`self.state` と `self.signalingChannel` を読む |
| 6 | `Sora/PeerChannel.swift` | `self` (`PeerChannel?`) | `PeerChannel.scheduleDisconnectTimerIfNeeded()` が `DispatchQueue.global(qos: .background).asyncAfter(deadline:execute:)` へ渡す block で `[weak self]` を取り、`self.disconnectTimerGeneration` / `self.handleConnectionEvent(_:)` / `self.state` / `self.disconnect(error:reason:)` を使う |
| 7 | `Sora/MediaChannel.swift` | `self` (`MediaChannel?`) | `MediaChannel.connect(webRTCConfiguration:onPrepared:handler:)` が `DispatchQueue.global().async(execute:)` へ渡す block で `[weak self]` を取り、`self?.basicConnect(connectionTask:)` を呼ぶ |
| 8 | `Sora/MediaChannel.swift` | `ConnectionTask` | 同じ `MediaChannel.connect` の block が、接続試行の `ConnectionTask` (局所名は `task`) を強参照で捕捉する |
| 9 | `Sora/MediaChannel.swift` | `self` (`MediaChannel?`) | `MediaChannel.getStats(handler:)` が `RTCPeerConnection.statistics(_:)` へ渡す完了 closure で `[weak self]` を取り、`self.state` と `self.peerChannel.nativeChannel` を読む |
| 10 | `Sora/DataChannel.swift` | `DataChannel` | `BasicDataChannelDelegate.dataChannel(_:didReceiveMessageWith:)` が `RTCPeerConnection.statistics(_:)` へ渡す完了 closure の内側で、`peerChannel.dataChannels` から取り出した `DataChannel` (局所名は `dc`) の `send(_:)` を呼ぶ |

警告が出るのは、WebRTC の Objective-C block と `DispatchQueue` の block が `@Sendable` closure として取り込まれるためである (`0173` の (A) / (B) 群と同じ原因)。

捕捉対象の型ごとの状態所有は、実コードでは次の状態にある。

- `PeerChannel` (internal。`Sora/PeerChannel.swift`)
  - 接続状態フラグ 5 つ (`isRedirecting` / `webSocketDisconnectScheduled` / `disconnectTimerScheduled` / `dataChannelGeneration` / `disconnectTimerGeneration`) は `ConnectionStateOwner` が単一所有し、`ConnectionSnapshotStorage` の snapshot 経由で読む。`handleConnectionEvent(_:)` が更新経路である (`0100` / `0101` の成果)。
  - `isAudioInputInitialized` は `var isAudioInputInitialized: Bool = false` として宣言され、読み (`PeerChannel.initializeAudioInput()` の先頭) と書き (`RTCAudioSession.initializeInput(_:)` の完了 closure) のいずれも lock 保護を持たない。所有者と保護区間が未定である。
  - `nativeChannel` / `onConnect` / `dataChannels` / `switchedToDataChannel` / `signalingOfferMessageDataChannels` / `rpcChannel` / `streams` / `offerEncodings` は lock 保護のない `var` である。`PeerChannel.Lock` (プロパティ名 `lock`) が保護すると doc コメントに書かれているのは `count` / `isDisconnecting` / `shouldDisconnect` であり、これら `var` の相互排他ではない。`lock` は非同期処理の生存数と切断の遅延を管理するためのもので、表の 2 / 3 の closure が `self` を読む間も `lock` の count が残るだけで、`nativeChannel` などの読み書きを直列化しない。
  - `webRTCConfiguration` は `webRTCConfigurationLock` 配下で読み書きする。`signalingChannel` と `snapshot` は `let` である。
  - したがって表の 1 から 6 の経路には、`PeerChannel` の状態を `Sendable` と主張できる排他が無い。
- `MediaChannel` (public。`Sora/MediaChannel.swift`)
  - `connectionLifecycleLock` (NSLock) が接続ライフサイクル (`state` / `currentConnectionTask` / `hasStartedConnection` / `disconnectPreparation` / `disconnectFinished` など) の遷移を直列化する。ただし `state` は `public private(set) var state: ConnectionState` であり、`isAvailable` や表の 9 の closure など lock の外から読む箇所がある。
  - 表の 7 が呼ぶ `basicConnect(connectionTask:)` は、内部で `connectionLifecycleLock` を取る。
  - `WeakMediaChannelBox` は「MediaChannel 自体を Sendable とせず、終端処理だけを lifecycle lock 配下へ戻す」用途限定の box として既にある。`startDisconnectPreparation(error:)` の `Task { @Sendable in ... }` から `weakSelf.value?.completeDisconnectPreparation()` を呼ぶ経路だけで使い、doc コメントに用途を限定している。
  - `MediaChannelGetStatsContext` は `0173` が追加した box で、handler と `RTCPeerConnection` だけを保持し、`MediaChannel` は保持しない。
  - `MediaChannel` は公開型であり、`TestConsumers/Swift6Consumer/NegativeChecks/core-sendable-capture.swift` が「`Sendable` ではないこと」を負例として固定している。`Sendable` 準拠を足すと公開 API baseline (準拠の追加) の再生成とこの負例の変更が必要になる。
- `ConnectionTask` (public。`Sora/Sora.swift`)
  - 可変状態は `stateLock` (NSLock) が保護する `_internalState` と `_peerChannel` だけである。`state` / `attach(peerChannel:)` / `markCanceled()` / `tryComplete()` / `complete()` / `cancel()` のいずれも `stateLock` を取る。ロックを保持したまま callback を呼ばない設計は `0165` で入っている。
  - 公開型 (`public final class ConnectionTask`) であり、公開 API baseline に `ConnectionTask` / `ConnectionTask.State` / `state` / `cancel()` が現れる。`Sendable` 準拠を足すと baseline の再生成が必要になる。
  - `SoraTests/SendableConformanceTests.swift` は現在 `ConnectionTask.State` だけを対象にしており、`ConnectionTask` 本体の準拠は固定していない。
- `DataChannel` (internal。`Sora/DataChannel.swift`)
  - `class DataChannel` の格納プロパティは `let native: RTCDataChannel` と `let delegate: BasicDataChannelDelegate` の 2 つだけで、可変状態を持たない。`compress` は `delegate.compress` (`let`) を返す computed property で、`send(_:)` は `native.sendData(_:)` を呼ぶ。
  - 状態は `RTCDataChannel` (WebRTC) と `BasicDataChannelDelegate` (`weak var peerChannel` / `weak var mediaChannel`) が持つ。`BasicDataChannelDelegate` の 2 つの `weak var` は `let` ではない。
  - 内部型であり、公開 API baseline に現れない。

## 設計方針

方針は、表の 10 件を経路ごとに「捕捉対象の型の状態所有を整理して `Sendable` を主張する」か「参照だけを保持する box を使う」のどちらかで解消することである。box を使う場合も、box が隠してよいのは捕捉対象の参照だけで、その参照が closure の内側で読み書きする状態が既存の排他または不変性で守られている経路に限る。守られていない状態を box で包んで `@unchecked Sendable` を付けるのは `0108` の「未完了項目を隠してはならない」に反するため、行わない。

`0108` は box を認める判定として「型自身が可変状態を持たず `init` で確定した不変値だけを保持すること」「変更前から同じ系統の非同期境界へ渡されており配送先・順序・呼び出し回数を変えないこと」「保持するのが closure と、その closure が変更前から一緒に捕捉していた参照だけで、SDK 内部の参照型を新たに保持しないこと」の 3 条件を挙げている。本 issue は `0173` の `## スコープ外` の結論に従い、SDK 内部の参照型を保持する box を一律に認めない。参照保持 box を使う経路では、3 条件の 3 番目を「box が保持してよいのは、closure が読み書きする状態が既存の排他または不変性で守られている参照だけである」と読み替えて適用し、経路ごとの根拠を box の doc コメントと「解決方法」に書く。前例の `PeerChannelDisconnectCompletionContext` は `PeerChannel` を強参照で保持するが、これは切断処理が `lock` の管理下にある経路へ戻す用途であり、排他に閉じない状態を closure が読む経路には適用できない。

- `PeerChannel` (表の 1 から 6)
  - `isAudioInputInitialized` の所有権と保護区間を決める。`0151` (`PeerChannel.onConnect` のデータ競合) が同じ「排他保護のない handler 用の `var`」を扱い、`0129` (`PeerChannel.Lock` の統合) が保護区間の統合先を決めるため、両者の結論と整合させる。`ConnectionStateOwner` のような単一所有者へ寄せるか、既存の `lock` の対象に含めるかを、両 issue の設計に合わせて選ぶ。
  - `nativeChannel` などの lock 保護のない `var` を closure が読む経路 (表の 2 から 6) は、参照だけを保持する box で包んでも排他が無い状態を隠すことになる。状態所有を整理するか、closure が読む値を `Sendable` な値へ写して `self` を読まない形にするかを経路ごとに選ぶ。世代 (`dataChannelGeneration` / `disconnectTimerGeneration`) は `ConnectionSnapshotStorage` の snapshot から `Sendable` な値として取り出せるため、値の写しで消せる候補である。
  - `PeerChannel` は internal のため、`Sendable` 準拠を選んでも公開 API baseline と consumer package に影響しない。
- `MediaChannel` (表の 7 と 9)
  - `WeakMediaChannelBox` の前例を適用できるのは、closure の状態アクセスが `connectionLifecycleLock` 配下に閉じる経路に限る。表の 7 は `basicConnect(connectionTask:)` を呼ぶだけで、`basicConnect` 自身が `connectionLifecycleLock` を取るため、前例の適用候補である。ただし box を使う場合も、`MediaChannel` を `Sendable` と主張しないことと、新しい並行境界を増やさないことを doc コメントに書く。
  - 表の 9 は `self.state` と `self.peerChannel.nativeChannel` を lock の外で読む。この読みを `connectionLifecycleLock` 配下へ戻すか、`state` を `Sendable` な値として closure へ渡すか、`MediaChannel` の状態所有を整理するかを選ぶ。
  - 公開型 `MediaChannel` に `Sendable` 準拠を足す場合は、後方互換のない変更としてカテゴリを `change` に見直し、公開 API baseline の再生成と `TestConsumers/Swift6Consumer/NegativeChecks/core-sendable-capture.swift` の更新 (負例の対象を別の非 `Sendable` 型へ移すか、負例自体を削除する) を同じ変更に含める。**この判断は実装着手前に確定する。`change` を選ぶ場合は、本 issue のカテゴリ・ファイル名・`Branch:` を見直す** (本 issue は `refactor` / `feature/refactor-remove-sora-internal-instance-captures` として起票している)。
- `ConnectionTask` (表の 8)
  - 可変状態が `stateLock` で保護されているため、`@unchecked Sendable` の主張は「未完了項目を隠す」ではなく「既存の排他で状態所有が確定している」ことに基づけられる。`Sendable` 準拠を足す場合は、`stateLock` が `_internalState` と `_peerChannel` の全アクセスを保護していることを doc コメントに書き、公開型のため同じ変更で公開 API baseline を再生成する。`SoraTests/SendableConformanceTests.swift` に `ConnectionTask` 本体の準拠の固定を追加する。
  - 準拠を足さない場合は、表の 7 と 8 をまとめて扱う。`MediaChannel.connect` は `currentConnectionTask` に `task` を保持するため、`ConnectionTask` を捕捉しない形へ接続開始経路を整理できるかを確認する。どちらを採るかは `MediaChannel` の判断と合わせて決める。
- `DataChannel` (表の 10)
  - 可変状態を持たない内部型であるため、`@unchecked Sendable` の主張は「保持する参照が `init` で確定した `let` で、`DataChannel` 自身は状態を持たず、状態は `RTCDataChannel` と `BasicDataChannelDelegate` が持つ」ことに基づけられる。`BasicDataChannelDelegate` の `weak var peerChannel` / `weak var mediaChannel` は `let` ではないため、`delegate` 経由で見える状態の所有を確認してから準拠を決める。
  - 準拠を足さない場合は、closure が `dc.send(_:)` を呼ぶだけで `DataChannel` の他の状態を読まないことを根拠に、`dc` を参照だけ保持する box で包む。
  - 内部型のため、どちらを選んでも公開 API baseline には影響しない。
- 公開 API の closure 引数の型を `@Sendable` に変えない (`0110` / `0173` の方針を維持する)。
- `@preconcurrency` の追加、`Sora` target の default actor isolation の MainActor 化、`@unchecked Sendable` を理由の記録なしに付けることでは消さない。
- 追加・変更する box と `Sendable` 準拠の doc コメントには、次を日本語で書く。ソースコードに issue 番号は書かない。
  - `Sendable` を主張できる根拠 (既存の排他、または `init` で確定した不変値であること)
  - 新しい並行境界を増やしていないこと (配送先・順序・呼び出し回数を変えないこと)
  - 捕捉対象の状態の所有と同期が誰の責務か
  - コメントの粒度の前例は `MediaChannelGetStatsContext` / `CreateAnswerHandlerBox` (`0173` が追加)、参照だけを保持する box の前例は `WeakMediaChannelBox` / `PeerChannelDisconnectCompletionContext` である。

## 前提となる issue

- `0173` (完了 2026-09-28): 切り分けの根拠。`## スコープ外` が本 issue の 10 件 (C 群) を切り分け、用途限定 box で包まない理由と、`MediaChannel` / `ConnectionTask` が公開型のため `Sendable` 準拠の是非も含めて判断することを書いている。本 issue はこの切り分けを引き継ぐ。
- `0108` (open): Sora target の warnings-as-errors 化。本 issue の完了が `0108` の前提であり、その逆ではない。`0108` は本 issue を未起票として扱っているため、本 issue の起票後に `0108` 側の記述を更新する必要がある。この更新は `0108` 側の作業として行い、本 issue の変更対象には含めない。
- `0115` (pending): `Utilities.Stopwatch` を削除する。`Sora/Utilities.swift` の 1 件はこの削除で消える。本 issue は `0115` を待たない。`0115` が先に完了した場合は、完了条件の「残る 1 件」を 0 件として読み替える。
- `0151` (open): `PeerChannel.onConnect` のデータ競合。`PeerChannel` の排他と状態所有の結論と整合させる。本 issue は `0151` の変更対象を書き換えない。
- `0129` (open): `PeerChannel.Lock` を接続状態 reducer へ統合する。`isAudioInputInitialized` の所有者と保護区間の決定先になり得るため、結論と整合させる。本 issue は `0129` の変更対象を書き換えない。

## 変更対象

- `Sora/PeerChannel.swift`: 表の 1 から 6 (`PeerChannel.initializeAudioInput()` / `PeerChannel.createAnswer` / `PeerChannel.handleSignalingOverWebSocket(_:)` / `PeerChannel.scheduleWebSocketDisconnectIfNeeded()` / `PeerChannel.scheduleDisconnectTimerIfNeeded()`)。状態所有の整理、`Sendable` 準拠、参照保持 box、`Sendable` な値の写しのいずれか
- `Sora/MediaChannel.swift`: 表の 7 から 9 (`MediaChannel.connect(webRTCConfiguration:onPrepared:handler:)` の `self` と `ConnectionTask`、`MediaChannel.getStats(handler:)` の `self`)。`connectionLifecycleLock` の区間整理、`WeakMediaChannelBox` の適用、`Sendable` 準拠のいずれか
- `Sora/DataChannel.swift`: 表の 10 (`BasicDataChannelDelegate.dataChannel(_:didReceiveMessageWith:)` の `DataChannel`)。`Sendable` 準拠か参照保持 box
- 公開型 `MediaChannel` / `ConnectionTask` に `Sendable` 準拠を足す場合
  - `TestConsumers/Swift6Consumer/ApiBaseline/`: 準拠の追加を同じ変更で再生成する (`CODEBASE.md` の baseline 更新手順に従う)
  - `TestConsumers/Swift6Consumer/NegativeChecks/core-sendable-capture.swift`: `MediaChannel` を負例から外す場合は、負例の対象を別の非 `Sendable` 型へ移すか、負例自体を削除する (`0107` の検証内容を空にしない)
  - `SoraTests/SendableConformanceTests.swift`: 追加した準拠を固定する (`ConnectionTask` 本体を対象に加える)

## テスト方針

モックやスタブは使用しない。検証は Xcode 26.6 と `iphoneos26.5` の環境で行い、版数は着手時点の `Makefile` の `API_XCODE` / `XCODE_SDK` に読み替える。

- 実装前後の型検査 log を比較する。`build/` は `.gitignore` の対象で fresh な checkout には無いため、log を取る前に `mkdir -p build` を実行し、`-F` には `swift package resolve` が作る xcframework の slice ディレクトリを指定する。

  ```
  swiftc -typecheck -swift-version 6 -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -target arm64-apple-ios14.0-simulator \
    -F .build/artifacts/sora-ios-sdk/WebRTC/WebRTC.xcframework/ios-arm64-simulator \
    -module-cache-path build/module-cache $(find Sora -name '*.swift') 2>&1 | tee build/0177-typecheck-after.log
  ```

- 実装後の log で `#SendableClosureCaptures` が `Sora/Utilities.swift` の `Utilities.Stopwatch` の 1 件だけになること。`0115` が先に完了している場合は 0 件になること。`#no-usage` などの新しい警告が増えていないことを一次行の総数で確認する。
- `0108` のゲート相当の flags を付けた型検査で error が 1 件 (`0115` 完了後は 0 件) だけであること。

  ```
  swiftc -typecheck -disable-batch-mode -continue-building-after-errors \
    -swift-version 6 -warnings-as-errors -Wwarning DeprecatedDeclaration \
    -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -target arm64-apple-ios14.0-simulator \
    -F .build/artifacts/sora-ios-sdk/WebRTC/WebRTC.xcframework/ios-arm64-simulator \
    -module-cache-path build/module-cache $(find Sora -name '*.swift') 2>&1 | tee build/0177-gate-after.log
  ```

- 表の 10 件それぞれについて、対象の closure が捕捉するのが `Sendable` な値か、状態アクセスが既存の排他に閉じた参照だけになったことを型検査で確認する。型検査 log の `capture of` が該当する file とシンボルから消えていることを示し、あわせて `git grep` で対象シンボルの参照箇所が想定どおりに整理されていることを示す。
- `make build` が成功し、`SoraTests` が失敗 0 件であること。`PeerChannel` の状態所有を変えた場合は、変更した経路の回帰テストを追加してから全体を回す。Thread Sanitizer は `0119` に従い完了条件に含めない。
- `make consumer-build SCHEME=ConsumerCore` と `make api-check-fresh` が成功すること。公開型に `Sendable` 準拠を足す場合は `make api-baseline` で再生成し、`git diff -- TestConsumers/Swift6Consumer/ApiBaseline/` を読んで準拠の追加以外の差分 (型の変更、準拠の削除、`printedName` / `declKind` の変化) が無いことを確認する。足さない場合は `git diff --exit-code -- TestConsumers/Swift6Consumer/ApiBaseline/` が空であること。
- `MediaChannel` の負例を変更する場合は `make consumer-check-negative` が成功すること。
- `make fmt-lint` と `make lint` が成功すること。

## 完了条件

- `Sora/` の Swift 6 言語モードの型検査で `#SendableClosureCaptures` が、表の 10 件が消えて `Sora/Utilities.swift` の `Utilities.Stopwatch` の 1 件だけになること (`0115` が先に完了している場合は 0 件)。`0108` のゲート相当の flags を付けた型検査の error が 1 件 (または 0 件) だけであること。
- 表の 10 件のそれぞれについて、`Sendable` を主張する根拠 (既存の排他、または `init` で確定した不変値であること) と、新しい並行境界を増やしていないことが日本語コメントで書かれ、コメントに issue 番号が書かれていないこと。参照だけを保持する box を使った経路には、捕捉対象の状態アクセスが既存の排他または不変性で守られている根拠が書かれていること。
- `Sendable` 準拠を足した型には、準拠の根拠が doc コメントに書かれていること。公開型に足した場合は、同じ変更で公開 API baseline が再生成され `make api-check-fresh` が成功し、`MediaChannel` に足した場合は `core-sendable-capture.swift` の負例が更新または削除されていること。
- 公開 API のシグネチャと利用者に見える挙動を変えていないこと。`@Sendable` 化、`@preconcurrency` の追加、default actor isolation の MainActor 化で警告を消していないこと。
- `make build`、`SoraTests` (失敗 0)、`make consumer-build SCHEME=ConsumerCore`、`make api-check-fresh`、`make fmt-lint`、`make lint` が成功すること。負例を変更した場合は `make consumer-check-negative` も成功すること。
- 実装着手前に、公開型 `MediaChannel` / `ConnectionTask` の `Sendable` 準拠の是非と、それに伴うカテゴリ (`refactor` か `change` か) が確定していること。`change` を選んだ場合は、ファイル名と `Branch:` が `feature/change-...` に見直されていること。

## スコープ外

- `Sora/Utilities.swift` の `Utilities.Stopwatch` の 1 件。`0115` の削除で消える。本 issue は `0115` を待たず、`0115` の変更対象も書き換えない。
- `#DeprecatedDeclaration` 警告。`0108` の `.treatWarning("DeprecatedDeclaration", as: .warning)` で warning のまま残す (`0138` が対象外とする iOS SDK 由来の deprecation 警告を error にしないため)。
- test target の warnings-as-errors ゲート (`0171`)。
- `PeerChannel.onConnect` のデータ競合そのもの (`0151`) と `PeerChannel.Lock` の統合そのもの (`0129`)。本 issue は結論と整合させるだけで、両 issue の変更対象を書き換えない。
- `issues/0108-update-swiftpm-language-mode.md` の担当記述の更新。本 issue の起票後に `0108` 側の作業として行う。
- `@preconcurrency` の追加と default actor isolation の変更で警告を消すこと (本 issue では行わない)。

## 解決方法
