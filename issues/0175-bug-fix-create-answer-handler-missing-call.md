# `createAnswer` で `self` が解放済みの経路でも handler を呼び、呼び出し元の lock 残留を防ぐ

- Created: 2026-09-28
- Completed:
- Priority: Low
- Branch: feature/fix-create-answer-handler-missing-call
- Polished: 2026-09-28

## 目的

`Sora/PeerChannel.swift` の `PeerChannel.createAnswer(isSender:offer:constraints:initialOffer:mid:generation:handler:)` が `nativeChannel.setRemoteDescription(_:completion:)` へ渡す closure は、先頭の `guard let self else` で handler を呼ばずに return する。

`createAndSendAnswer` と `createAndSendUpdateAnswer` は `createAnswer` を呼ぶ前に `lock.lock()` を取得し、handler の完了で `lock.unlock()` を呼ぶ契約である。`Lock.unlock()` は `count` を減らし、`count == 0` になった時点で保存済みの切断要求を `basicDisconnect()` へ渡すため、この経路では handler が呼ばれないと取得済みの lock が解放されず、`basicDisconnect()` が実行されないままになり得る。

本 issue は、この経路でも handler を必ず 1 回呼び、`createAnswer` のすべての return 経路で handler が厳密に 1 回呼ばれる契約にする。`0093` が `nativeChannel` が nil の 3 経路を修正したときの方針（handler を必ず 1 回呼ぶ契約は lock 残留を防ぐ不変条件として、到達状況に関わらず満たす）を、残るこの 1 経路にも適用する。修正はこの 1 経路に限定し、到達可能な 4 経路の handler の呼び出し回数と通知内容は変更しない。

## 現状

### 該当箇所

`Sora/PeerChannel.swift` の `PeerChannel.createAnswer` は、`nativeChannel.setRemoteDescription(_:completion:)` に `[weak self]` の closure を渡し、その先頭で次を実行する。

```swift
guard let self else {
  // この経路では handler を呼ばずに return する。呼び出し元は handler の完了で lock を
  // 解放するため、handler が呼ばれないと lock が残留し得る。この挙動は変更せず、
  // 扱いは別 issue に委ねる。
  return
}
```

`handler` は `createAnswer` の先頭で `CreateAnswerHandlerBox`（`@unchecked Sendable` の private な用途限定 box）に包まれ、他の return 経路はすべて `handlerBox(...)` を 1 回呼んでいる。handler を呼ばない経路はこの 1 つだけである。

同じ `createAnswer` の `guard let nativeChannel else` の経路（処理開始時 / `setRemoteDescription` 完了後 / `answer(for:completion:)` 完了後の 3 箇所）は `0093` で handler を呼ぶ形に修正済みで、コメントも「handler を呼ばずに return すると、呼び出し元が lock を解放できない (ロック残留)。明示的な接続失敗として handler を必ず 1 回呼ぶ。」と書かれている。`0093` の修正対象は `nativeChannel` が nil の 3 経路だけであり、この経路は未対応のまま残っている。

### 呼び出し元の契約

`createAnswer` の呼び出し元は 4 つあり、lock の取得位置が 2 通りある。

- `PeerChannel.createAndSendAnswer(offer:)`: `PeerChannel.handleSignalingOverWebSocket(_:)` の `.offer` で `lock.lock()` を取得した状態で `createAnswer` を呼び、handler の中で `self.lock.unlock()` を呼ぶ。handler が呼ばれないと取得済みの lock が解放されない。
- `PeerChannel.createAndSendUpdateAnswer(forOffer:)`: `createAnswer` の直前に `guard lock.lock() else` で取得し、handler の中で `self.lock.unlock()` を呼ぶ。同じく handler が呼ばれないと lock が解放されない。
- `PeerChannel.createAndSendReAnswer(forReOffer:)` と `PeerChannel.createAndSendReAnswerOverDataChannel(forReOffer:)`: handler の先頭で `guard self.lock.lock() else` を呼ぶ。handler が呼ばれないと lock を取得しないため lock 残留にはならないが、answer の送信、`internalHandlers.onUpdate` の通知、`disconnect` が行われない。

### `CreateAnswerHandlerBox` の契約と排他性

`CreateAnswerHandlerBox` は handler を `let` で保持し、`callAsFunction(_:_:)` は `handler(sdp, error)` を呼ぶだけで `PeerChannel` を参照しない。box の doc コメントの使用契約は現在「高々 1 回だけ呼ばれるが、複数の closure から参照される」である。

`createAnswer` の handler を呼ぶ経路は、この `guard let self else` の節、`guard let nativeChannel else` の 3 箇所、世代不一致の 2 箇所（`handlerBox(nil, nil)`）、`setRemoteDescription` / `answer(for:)` / `setLocalDescription` の各エラー経路、成功経路である。この節は `self` が nil のときにだけ通り、他の呼び出しはすべて `guard let self else` の後（`self` が non-nil のとき）にだけ到達する。1 回の closure 実行で両方が成立しないため、この節から呼んでも handler は 2 回呼ばれない。

### 到達性

この経路は現状到達しない。理由は「handler が `self` を強参照する」ことだけではなく、**この経路が成立するには `PeerChannel` の解放後も `nativeChannel` の callback が届く必要があるが、その所有関係が無い**ことにある。

- 4 つの呼び出し元が渡す handler の closure はいずれも `self` を強参照で捕捉している（`[weak self]` を使っていない）。
- `CreateAnswerHandlerBox` は handler を `let` で強参照し、`setRemoteDescription` に渡す closure は `handlerBox(...)` を呼ぶため box を強参照で捕捉する。
- `createAnswer` の `offer` / `constraints` は引数、`offerDescription` は値であり、この closure が `self` を直接参照するのは `self.dataChannelGeneration` と `self.nativeChannel` を読む箇所である。したがって closure が実行される時点では handler 経由で `PeerChannel` が強参照されており、`self` は解放されていない。
- `nativeChannel` は `PeerChannel` のプロパティ（強参照）であり、`Sora/` で `nativeChannel` へ代入するのは `PeerChannel.createAndSendAnswer(offer:)` の 1 箇所だけである。`PeerChannel` が解放されれば `RTCPeerConnection` への強参照も失われ、`setRemoteDescription` の完了 block は呼ばれ得ない。つまり「closure が呼ばれる」と「`self` が nil」は同時に成立しない。
- 補足として `PeerChannel.lock` は `let` であり、`peerChannel.lock` を保持する型は `Sora/` に無い（`PeerChannel` だけが強参照する）。`self` が解放される状況では `Lock` も一緒に解放される。ただしこれは上の所有関係の帰結であり、この節の到達性を支える根拠ではない。

この経路が `nativeChannel` の callback として実行される限り、`self` が nil になることは `PeerChannel` の所有関係上あり得ない。それでも契約を満たすのは、`0093` の方針に従うためである。契約は型でもテストでも固定できないため、`nativeChannel` の所有や `createAnswer` の呼び出し元が変わったときにだけ意味を持つ。

### `Sora/` で同じ形の経路の有無

`Sora/` の `guard let self` 10 件を全件確認した。完了 callback（または handler）を呼ばずに return する経路は 2 件あり、呼び出し元の lock を保持したままになり得るのは `PeerChannel.createAnswer` と `PeerChannel.sendConnectMessage(error:)` である。前者は本 issue が扱い、後者は `0007` が実害なしと判断済みである。他は次の理由で該当しない。

- `MediaChannel.getStats(handler:)` が `peerConnection.statistics` へ渡す closure は、`guard let self else` でも `context.handler(.failure(SoraError.peerChannelError(reason: "MediaChannel is unavailable")))` を呼ぶ。同じ状況で同じ理由の文言を使っており、本 issue が渡すエラーの前例になる。
- `MediaChannel.basicConnect(connectionTask:)` が `peerChannel.connect` へ渡す完了 closure は `guard let self else` で return するが、`connectionLifecycleLock` は `peerChannel.connect` を呼ぶ前に解放済みで、この完了で解放する lock を持たない。
- `MediaChannel` が `peerChannel.internalHandlers.onDisconnect` へ設定する closure は `self` が nil でも `task.complete()` を呼ぶ。
- `ConnectionTimer.run(timeout:handler:)` の `Timer` の block、`PeerChannel.scheduleWebSocketDisconnectIfNeeded()` と `PeerChannel.scheduleDisconnectTimerIfNeeded()` の `DispatchQueue` の block、`PeerChannel.handleSignalingOverWebSocket(_:)` の `.ping` の `statistics` の closure、`DummyAudioDevice.terminateDevice()` の closure は、handler の完了で lock を解放する契約を持たない。
- `PeerChannel.sendConnectMessage(error:)` が `NativePeerChannelFactory.createClientOfferSDP` へ渡す完了 closure も `guard let self else` で return し、接続開始時の初期 lock を解放しない形になり得る。ただし `0007` が「`self` が nil でリターンすると `lock.unlock()` が呼ばれないが、PeerChannel 自体が解放済みであれば Lock も解放されるため実害なし」と判断済みで、`createAnswer` の handler 契約とは別の経路である。本 issue では扱わない。

## 優先度根拠

利用者が観測できる不具合ではなく、現状到達しない防御経路の契約違反である。この修正で利用者に見える挙動は変わらない。一方で、`0093` が確立した「handler を必ず 1 回呼ぶ」不変条件がこの 1 経路だけ破れている。修正は小さく、公開 API と `0108` の gate に影響しないため Low とする。

`0093` の `CHANGES.md` の `[FIX]` エントリは「`createAnswer` で `nativeChannel` が nil の場合に handler を呼ばずに return し、切断処理が行われず接続が残ってしまう問題を修正する」であり、利用者に観測できる問題を修正したものである。本 issue の経路は到達しないため、`CHANGES.md` には同じ「接続が残る」という症状ではなく、handler の契約を満たすための防御的修正であることが分かる文言で記録する。

## 前提となる issue

- `0093` (完了 2026-08-28): `createAnswer` の `nativeChannel` nil の 3 経路で handler を必ず 1 回呼ぶ形に修正し、「到達状況に関わらず契約を満たす」方針を確立した。本 issue はその残り 1 経路を扱う。
- `0007` (完了): `createAnswer` のネスト closure への `[weak self]` 付与を検討し、呼び出し元の handler が lock / unlock と disconnect を担うため「`self` が nil でこれらの処理がスキップされると、接続状態の遷移が中途半端になる」として、この箇所を「単体でのリスクが低い」と判断して見送った。本 issue はその見送りを解消する。
- `0173` (完了 2026-09-28): `CreateAnswerHandlerBox` を導入し、box の doc コメントに使用契約を「高々 1 回だけ呼ばれる」と書き、本経路に「扱いは別 issue に委ねる」コメントを残した。本 issue がその別 issue にあたる。box の `@unchecked Sendable` の根拠の 1 つが「可変状態を持たない」ことであるため、本 issue は box に可変状態を追加しない。
- `0177` (open): `#SendableClosureCaptures` のうち SDK 内部インスタンスを捕捉する 10 件を解消する。`## 現状` の表 2 が `createAnswer` の `setRemoteDescription` 完了 closure、表 3 が同じ `createAnswer` の `answer(for:)` 完了 closure を対象にしており、`## 設計方針` は表 2 から `[weak self]` を外すのではなく closure が読む値を `Sendable` な値へ写して `self` を読まない形にする方針である。この方針が適用されると、本 issue が扱う `guard let self else` の節が残るか消えるかが変わる。**実装順は `0177` を先とし、`0177` の完了後にこの節の有無を確認してから本 issue に着手する。** `0177` の完了でこの節が消えている場合は、本 issue は「`createAnswer` に handler を呼ばずに return する経路が無いことを型検査と `grep` で確認する」に縮小し、その旨を「解決方法」に記録して close する。
- `0126` (open): `createAnswer` 等の非同期処理の完了が返らない場合に、切断クリーンアップのタイムアウトと強制 teardown を追加する。本 issue の経路は「完了が返らない」ではなく「handler を呼ばずに return する」既知の経路であり、`0126` は症状への安全網、本 issue は原因側の 1 経路の解消である。重複しない。
- `0129` (open、Priority: Medium): `PeerChannel.Lock` を接続状態 reducer へ統合する。統合後も `createAnswer` の handler が呼び出し元の lock 解放を担う契約を維持する必要がある。本 issue は `Lock` 自体を変更せず、`lock.lock()` / `lock.unlock()` / `Lock.waitDisconnect` の呼び出しも変更しないため `0129` とは独立して実施できるが、同じ file の同じ経路を触るため `0129` の完了後に rebase する。
- `0176` (open): `MediaChannel.getStats` と `createClientOfferSDP` の参照保持 box の回帰テストを追加する。本 issue の `.offer` / `.update` 経路のテスト追加とは観測対象が異なり、重複しない。

## 設計方針

- `guard let self else` の節で、`self` を使わずに `handlerBox` を 1 回呼んで return する。`CreateAnswerHandlerBox` は handler だけを `let` で保持し、`callAsFunction(_:_:)` は `handler(sdp, error)` を呼ぶだけで `PeerChannel` を参照しない。`self` が解放済みでも handler を呼べる。呼び出しの位置は、この節の `Logger.debug` の後・`return` の前とする。
- この節から呼ぶ handler には、明示的なエラー（`SoraError.peerChannelError(reason: "PeerChannel is unavailable")`）と `nil` の SDP を渡す。呼び出し元の handler はエラー経路で lock を解放して切断へ進む契約であり、`nil, nil`（世代不一致の正常終了として扱う値）で通知すると異常経路を正常終了として扱うことになる。`reason` はログ規約に合わせて英語の固定文言とし、何を表す値かをコメントに書く。`MediaChannel.getStats` が同じ「利用者オブジェクトが解放済み」の状況で `"MediaChannel is unavailable"` を使っているため、文言の粒度をそれに合わせる。
- この節に「現状は到達しない理由」（handler が `self` を強参照し、`nativeChannel` が `PeerChannel` のプロパティであるため、closure が呼ばれることと `self` が nil であることが同時に成立しない）と「それでも契約を満たす理由」（`0093` の方針）を日本語コメントに残す。ソースコードに issue 番号は書かない。
- `CreateAnswerHandlerBox` の doc コメントの使用契約を「高々 1 回だけ呼ばれる」から「すべての return 経路で厳密に 1 回だけ呼ばれる」へ更新し、排他性の根拠（この節は `self` が nil のときだけ、他は non-nil のときだけ通る）を日本語で書く。あわせて「複数の closure から参照される」の説明が指す closure の数を現行のコードに合わせ、`@unchecked Sendable` の根拠 3 点と「`Sendable` にするのは入れ物だけ」という記述は変更しない。
- 到達可能な 4 経路の振る舞いを変更しない（handler の呼び出し回数と通知内容だけを契約に合わせる）。`createAnswer` の可視性（private）を変えず、この 1 経路のテストのために production コードへテスト専用の API を追加しない。
- `setRemoteDescription` の closure から `[weak self]` を外す案は採らない。`PeerChannel` は `Sendable` ではないため `#SendableClosureCaptures` の警告が 1 件増え、`0177` と `0108` の gate を塞ぐ。`guard let self` を削除する案も同じ理由で採らない。この節で `handlerBox` を呼ぶことは `self` を捕捉しないため、新しい `#SendableClosureCaptures` を発生させない。
- `CHANGES.md` の `## develop` の主リストの `[FIX]` 群の末尾に、`0093` のエントリと同じ粒度（見出し 1 行 + 補足行 + 担当者行）で追記する。症状（接続が残る）ではなく「handler の契約を満たす防御的修正であり利用者に見える挙動の変更はない」ことが分かる文言にする。

## 変更対象

- `Sora/PeerChannel.swift`: `PeerChannel.createAnswer` の `setRemoteDescription` 完了 closure の `guard let self else` 節に handler 呼び出しを追加し、`CreateAnswerHandlerBox` の doc コメントの使用契約を更新する
- `SoraTests/PeerChannelRedirectInvalidationTests.swift`: 変更しない。既存の `.reOffer` 経路のテストを到達可能な経路の handler 契約の回帰の正本として維持する（「テスト方針」のとおり新しいテストは追加しない）
- `CHANGES.md`: `## develop` の主リストの `[FIX]` 群の末尾にエントリを追加
- `PeerChannel.sendConnectMessage(error:)` の `createClientOfferSDP` 完了 closure と、`Sora/` の他の `guard let self` の経路は変更しない（「現状」のとおり `0007` が別経路として判断済み。同じ方針を適用するかは別 issue で判断する）
- `issues/SEQUENCE` と他の issue ファイルは変更しない

## テスト方針

モックやスタブは使用しない。

本 issue では新しいテストを追加しない。追加の根拠と、既存テストを回帰の正本にする理由は次のとおり。

- `self` 解放経路（本 issue が追加する handler 呼び出し）: テストでは再現できないため、テストを追加しない。理由は次の 2 点であり、どちらも production コードを変更せずには解消できない。
  - この節を通すには `createAnswer` の `setRemoteDescription` 完了 closure が `self` の解放後に実行される必要がある。しかし closure は `handlerBox` を強参照し、box の handler が `self` を強参照するため、closure が実行される時点で `self` は生存している。`self` を解放済みにするには handler の `self` 強参照を外す必要があり、それは `0007` が「接続状態の遷移が中途半端になる」として採らなかった変更である。
  - `handlerBox` は libwebrtc に渡す closure の内側で使うため、closure をテスト側で保持して後から呼ぶことも、`createAnswer` を internal にして直接呼ぶこともできない（`createAnswer` を internal にしても、`self` を解放した状態で完了 block を発火させる手段が無い）。テスト専用の API を production コードへ追加しないことは「設計方針」の制約である。
- 到達可能な経路の handler 契約: 既存の `SoraTests/PeerChannelRedirectInvalidationTests.testReAnswerFromReOfferProducesAnswerMatchingOfferMediaSections` の観測方法（実 `RTCPeerConnection` と audio track で有効な offer SDP を作り、`signalingChannel.internalHandlers.onReceive?(.reOffer(...))` から流し、`internalHandlers.onUpdate` の呼び出し回数が 1 回・`internalHandlers.onDisconnect` の呼び出し回数が 0 回であることを `XCTestExpectation` と `PeerChannelCallCounter` で固定する）を正本とする。この観測は、`.reOffer` の経路（DataChannel の signaling が無い場合は `createAndSendReAnswer`）の handler が 1 回だけ呼ばれ、エラー経路へ落ちていないことを固定する。`.update` 経路は `Configuration.multistreamEnabled` が `nil` のとき `snapshot.isMultistream` が true になるため到達でき、`setRemoteDescription` と `answer` の native 経路は `.reOffer` と同じである。この 2 経路の追加テストを作らないのは、本 issue の変更が `self` nil の 1 経路だけで、到達可能な経路の観測点を増やしても新しい契約を検証できないためである。
- `.offer` 経路（`createAndSendAnswer`）のテスト: 追加しない。この経路は `snapshot.isSender` が true のときに `initializeSenderStream` を呼び、`RTCAudioSession.initializeInput` とカメラの初期化という実機依存の副作用を持つ。`self` nil の経路の検証にはならず、native の answer 生成は `.reOffer` と同じ経路を通るため、回帰の代表は `.reOffer` のテストで足りる。`disconnect()` の後に `internalHandlers.onDisconnect` が 1 回呼ばれることを観測する案は、lock が残留していないことの確認にはなるが、本 issue の変更（`self` nil の節）を通らない経路の観測であり、`Lock.waitDisconnect` の仕様が変われば無関係に失敗するテストになるため採らない。
- `SoraTests` を実行し失敗 0 件であること。`.reOffer` のテストは単独で 10 回以上実行して flaky でないことを確認する。`make build`、`make fmt-lint`、`make lint`、`make api-check-fresh` が成功し、`git diff --exit-code -- TestConsumers/Swift6Consumer/ApiBaseline/` が空であること。
- `swiftc -typecheck -swift-version 6` で `Sora/` を型検査し、`#SendableClosureCaptures` の件数が実装前後で増えていないこと（`0177` の完了後の値と比較する。`0108` のゲートは `0177` と `0115` が残る限り開かないため、本 issue の完了条件には含めない）。

## 完了条件

- `PeerChannel.createAnswer` の `setRemoteDescription` 完了 closure の `guard let self else` 節で、`self` を使わずに `handlerBox` が 1 回呼ばれること（`self` を参照する式がこの節に残っていないこと）。`createAnswer` に handler を呼ばずに return する経路が残っていないことを、`createAnswer` の全 return 経路を読んで確認していること。
- `CreateAnswerHandlerBox` の doc コメントの使用契約が「すべての return 経路で厳密に 1 回」に更新され、排他性の根拠が日本語で書かれていること。box に可変状態を追加していないこと。
- 追加・変更するコメントに issue 番号が書かれていないこと。到達可能な 4 経路の handler の呼び出し回数と通知内容が変わっていないこと。
- `self` 解放経路をテストで再現できないことを `## テスト方針` と `## 解決方法` に記録していること。**この経路の handler 呼び出しはテストで観測しない。** `internalHandlers.onUpdate` / `internalHandlers.onDisconnect` の呼び出し回数は、到達可能な経路の handler が 1 回だけ呼ばれてエラー経路へ落ちていないことの観測値であり、`self` 解放経路の handler 呼び出し回数の観測値ではない。両者を取り違えた完了条件を書かないこと。
- 既存テストがすべて成功すること。`make build`、`make fmt-lint`、`make lint`、`make api-check-fresh` が成功し、`git diff --exit-code -- TestConsumers/Swift6Consumer/ApiBaseline/` が空であること。
- `CHANGES.md` の `## develop` の主リストの `[FIX]` 群の末尾に、利用者に見える挙動の変更がないことが分かる文言のエントリが担当者行付きで追加されていること。
- `Sora/` の Swift 6 言語モードの型検査で `#SendableClosureCaptures` が実装前より増えていないこと（`0177` の完了後の値と比較した実測を「解決方法」に記録していること）。この型検査は、この節で `handlerBox` を呼ぶことが `self` の新しい捕捉を生まないことの機械的な裏付けになる。
- `## 前提となる issue` の `0177` の項目に書いた実施順を守っていること。`0177` の完了でこの節が消えていた場合は、テストを追加せず「`createAnswer` に handler を呼ばずに return する経路が無いこと」の確認結果を「解決方法」に記録して close していること。
