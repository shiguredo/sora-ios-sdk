# `createAnswer` で `self` が解放済みの経路でも handler を呼び、呼び出し元の lock 残留を防ぐ

- Created: 2026-09-28
- Completed:
- Priority: Low
- Branch: feature/fix-create-answer-handler-missing-call
- Polished:

## 目的

`Sora/PeerChannel.swift` の `PeerChannel.createAnswer(isSender:offer:constraints:initialOffer:mid:generation:handler:)` が `nativeChannel.setRemoteDescription(_:completionHandler:)` へ渡す closure は、先頭の `guard let self else` で handler を呼ばずに return する。`createAndSendAnswer` と `createAndSendUpdateAnswer` は `createAnswer` を呼ぶ前に `lock.lock()` を取得し、handler の完了で `lock.unlock()` を呼ぶ契約であるため、この経路では取得済みの lock が解放されず、`basicDisconnect()` が実行されないままになり得る。

本 issue は、この経路でも handler を必ず 1 回呼び、`createAnswer` のすべての return 経路で handler が厳密に 1 回呼ばれる契約にする。`0093` が `nativeChannel` が nil の 3 経路を修正したときの方針（handler を必ず 1 回呼ぶ契約は lock 残留を防ぐ不変条件として、到達状況に関わらず満たす）を、残るこの 1 経路にも適用する。

## 現状

### 該当箇所

`Sora/PeerChannel.swift` の `PeerChannel.createAnswer` は、`nativeChannel.setRemoteDescription(_:completionHandler:)` に `[weak self]` の closure を渡し、その先頭で次を実行する。

```swift
guard let self else {
  // この経路では handler を呼ばずに return する。呼び出し元は handler の完了で lock を
  // 解放するため、handler が呼ばれないと lock が残留し得る。この挙動は変更せず、
  // 扱いは別 issue に委ねる。
  return
}
```

`handler` は `createAnswer` の先頭で `CreateAnswerHandlerBox`（`@unchecked Sendable` の private な用途限定 box）に包まれ、他の return 経路はすべて `handlerBox(...)` を 1 回呼んでいる。handler を呼ばない経路はこの 1 つだけである。

同じ `createAnswer` の `guard let nativeChannel else` の経路（処理開始時 / `setRemoteDescription` 完了後 / `answer(for:completionHandler:)` 完了後の 3 箇所）は `0093` で handler を呼ぶ形に修正済みで、コメントも「handler を呼ばずに return すると、呼び出し元が lock を解放できない (ロック残留)。明示的な接続失敗として handler を必ず 1 回呼ぶ。」と書かれている。`0093` の修正対象は `nativeChannel` が nil の 3 経路だけであり、この経路は未対応のまま残っている。

### 呼び出し元の契約

`createAnswer` の呼び出し元は 4 つあり、lock の取得位置が 2 通りある。

- `PeerChannel.createAndSendAnswer(offer:)`: `PeerChannel.handleSignalingOverWebSocket(_:)` の `.offer` で `lock.lock()` を取得した状態で `createAnswer` を呼び、handler の中で `self.lock.unlock()` を呼ぶ。handler が呼ばれないと取得済みの lock が解放されない。
- `PeerChannel.createAndSendUpdateAnswer(forOffer:)`: `createAnswer` の直前に `guard lock.lock() else` で取得し、handler の中で `self.lock.unlock()` を呼ぶ。同じく handler が呼ばれないと lock が解放されない。
- `PeerChannel.createAndSendReAnswer(forReOffer:)` と `PeerChannel.createAndSendReAnswerOverDataChannel(forReOffer:)`: handler の先頭で `guard self.lock.lock() else` を呼ぶ。handler が呼ばれないと lock を取得しないため lock 残留にはならないが、answer の送信、`internalHandlers.onUpdate` の通知、`disconnect` が行われない。

### `Sora/` で同じ形の経路の有無

`Sora/` の `guard let self else` を全件確認した。完了 callback（または handler）を呼ばずに return する経路は 2 件あり、呼び出し元の lock を保持したままになり得るのは `PeerChannel.createAnswer` と `PeerChannel.sendConnectMessage(error:)` である。前者は本 issue が扱い、後者は `0007` が実害なしと判断済みである。他は次の理由で該当しない。

- `MediaChannel.getStats(handler:)` が `peerConnection.statistics` へ渡す closure は、`guard let self else` でも `context.handler(.failure(...))` を呼ぶ。
- `MediaChannel.basicConnect(connectionTask:)` が `peerChannel.connect` へ渡す完了 closure は `guard let self else` で return するが、`connectionLifecycleLock` は `peerChannel.connect` を呼ぶ前に解放済みで、この完了で解放する lock を持たない。
- `ConnectionTimer.run(timeout:handler:)` の `Timer` の block、`PeerChannel.scheduleWebSocketDisconnectIfNeeded()` と `PeerChannel.scheduleDisconnectTimerIfNeeded()` の `DispatchQueue` の block、`PeerChannel.handleSignalingOverWebSocket(_:)` の `.ping` の `statistics` の closure、`DummyAudioDevice.terminateDevice()` の closure は、handler の完了で lock を解放する契約を持たない。
- `MediaChannel.basicConnect` の `internalHandlers.onDisconnect` の closure は `self` が nil でも `task.complete()` を呼ぶ。
- `PeerChannel.sendConnectMessage(error:)` が `NativePeerChannelFactory.createClientOfferSDP` へ渡す完了 closure も `guard let self else` で return し、接続開始時の初期 lock を解放しない形になり得る。ただし `0007` が「`self` が nil でリターンすると `lock.unlock()` が呼ばれないが、PeerChannel 自体が解放済みであれば Lock も解放されるため実害なし」と判断済みで、`createAnswer` の handler 契約とは別の経路である。本 issue では扱わない。

### 到達性

現状のコードでは、この経路は到達しないと考えられる。

- 4 つの呼び出し元が渡す handler の closure はいずれも `self` を強参照で捕捉している（`[weak self]` を使っていない）。
- `CreateAnswerHandlerBox` は handler を `let` で強参照し、`setRemoteDescription` に渡す closure は `handlerBox(...)` を使うため box を強参照で捕捉している。
- したがって closure が実行される時点では handler 経由で `PeerChannel` が強参照されており、`self` は解放されていない。
- `PeerChannel.lock` は `PeerChannel` だけが強参照しており（`peerChannel.lock` を保持する他の型は無い）、`self` が解放される状況では `Lock` も一緒に解放される。そのため現状の所有関係では、この経路で「解放されない lock」を外部から観測することはできない。

つまり「handler を呼ばない経路」が無いことは、handler が `self` を強参照するという暗黙の性質に依存しており、型でもテストでも固定されていない。この暗黙の性質（`self` が解放されるなら `Lock` も解放される）が崩れる変更、たとえば呼び出し元の handler が `self` を保持しなくなる、`Lock` の所有が `PeerChannel` の外へ移る、`createAnswer` の呼び出し元が増える、といった変更で lock 残留が実際に発生し得る。

## 優先度根拠

利用者が観測できる不具合ではなく、現状は到達しない防御経路の契約違反である。一方で、到達性を支えている性質がコード上に明示されておらず、`0093` が確立した「handler を必ず 1 回呼ぶ」不変条件がこの 1 経路だけ破れている。修正は小さく、公開 API と `0108` の gate に影響しないため Low とする。

## 前提となる issue

- `0093` (完了 2026-08-28): `createAnswer` の `nativeChannel` nil の 3 経路で handler を必ず 1 回呼ぶ形に修正し、「到達状況に関わらず契約を満たす」方針を確立した。本 issue はその残り 1 経路を扱う。
- `0007` (完了): `createAnswer` のネスト closure への `[weak self]` 付与を検討し、呼び出し元の handler が lock / unlock と disconnect を担うため「`self` が nil でこれらの処理がスキップされると、接続状態の遷移が中途半端になる」として、この箇所を「単体でのリスクが低い」と判断して見送った。本 issue はその見送りを解消する。
- `0173` (完了 2026-09-28): `CreateAnswerHandlerBox` を導入し、box の doc コメントに使用契約を「高々 1 回だけ呼ばれる」と書き、本経路に「扱いは別 issue に委ねる」コメントを残した。本 issue がその別 issue にあたる。box の `@unchecked Sendable` の根拠の 1 つが「可変状態を持たない」ことであるため、本 issue は box に可変状態を追加しない。
- `0126` (open): `createAnswer` 等の非同期処理の完了が返らない場合に、切断クリーンアップのタイムアウトと強制 teardown を追加する。本 issue の経路は「完了が返らない」ではなく「handler を呼ばずに return する」既知の経路であり、`0126` は症状への安全網、本 issue は原因側の 1 経路の解消である。重複しない。
- `0129` (open): `PeerChannel.Lock` を接続状態 reducer へ統合する。統合後も `createAnswer` の handler が呼び出し元の lock 解放を担う契約を維持する必要がある。
- `0177` (open): `#SendableClosureCaptures` のうち SDK 内部インスタンスを捕捉する 10 件を解消する。本 issue は `setRemoteDescription` の closure から `[weak self]` を外して `self` を強参照させる修正を採らない（新しい `#SendableClosureCaptures` を作らない）制約がある。

## 設計方針

- `guard let self else` の節で、`self` を使わずに `handlerBox` を 1 回呼んで return する。`CreateAnswerHandlerBox` は handler だけを `let` で保持し、`callAsFunction(_:_:)` は `handler(sdp, error)` を呼ぶだけで `PeerChannel` を参照しない。`self` が解放済みでも handler を呼べる。
- box の「高々 1 回」契約との整合は、分岐の排他性で取る。この節は `self` が nil のときにだけ通り、他の `handlerBox(...)` 呼び出しはすべて `guard let self else` の後（`self` が non-nil のとき）にだけ到達する。1 回の closure 実行で両方が成立しないため、box に可変状態や排他を追加せずに「すべての return 経路で厳密に 1 回」にできる。
- `CreateAnswerHandlerBox` の doc コメントの使用契約を「高々 1 回だけ呼ばれる」から「すべての return 経路で厳密に 1 回だけ呼ばれる」へ更新し、排他性の根拠（この節は `self` が nil のときだけ、他は non-nil のときだけ通る）を日本語で書く。`@unchecked Sendable` の根拠 3 点と「`Sendable` にするのは入れ物だけ」という記述は変更しない。
- この節から呼ぶ handler には、明示的なエラー（`SoraError.peerChannelError(reason: "PeerChannel is unavailable")`）と `nil` の SDP を渡す。呼び出し元の handler はエラー経路で lock を解放して切断へ進む契約であり、`nil, nil`（世代不一致の正常終了として扱う値）で通知すると異常経路を正常終了として扱うことになる。`reason` はログ規約に合わせて英語の固定文言とし、何を表す値かをコメントに書く。
- `setRemoteDescription` の closure から `[weak self]` を外す案は採らない。`PeerChannel` は `Sendable` ではないため `#SendableClosureCaptures` の警告が 1 件増え、`0177` と `0108` の gate を塞ぐ。`guard let self` を削除する案も同じ理由で採らない。
- この節が現状到達しない理由（handler が `self` を強参照し、box がその handler を、closure が box を強参照する）と、それでも契約を満たす理由（`0093` の方針）を日本語コメントに残す。ソースコードに issue 番号は書かない。
- 到達可能な 4 経路の振る舞いは変更しない（handler の呼び出し回数と通知内容だけを契約に合わせる）。
- `CHANGES.md` の `## develop` の `[FIX]` に、同じ契約違反を修正した `0093` のエントリと同じ粒度で追記する。

## 変更対象

- `Sora/PeerChannel.swift`: `PeerChannel.createAnswer` の `setRemoteDescription` 完了 closure の `guard let self else` 節に handler 呼び出しを追加し、`CreateAnswerHandlerBox` の doc コメントの使用契約を更新する
- `SoraTests/PeerChannelRedirectInvalidationTests.swift`: `createAnswer` の handler 呼び出し回数の回帰テストを追加する（既存の `testReAnswerFromReOfferProducesAnswerMatchingOfferMediaSections` と同じ helper と観測方法を使う）
- `CHANGES.md`: `## develop` の `[FIX]` へのエントリ追加
- `PeerChannel.sendConnectMessage(error:)` の `createClientOfferSDP` 完了 closure は変更しない（「現状」のとおり `0007` が別経路として判断済み。同じ方針を適用するかは別 issue で判断する）

## テスト方針

モックやスタブは使用しない。

- `.reOffer` 経路（`createAndSendReAnswer`）: 既存の `SoraTests/PeerChannelRedirectInvalidationTests.testReAnswerFromReOfferProducesAnswerMatchingOfferMediaSections` を維持し、実 `RTCPeerConnection` と audio track から作った有効な offer SDP を `signalingChannel.internalHandlers.onReceive` から流して、handler が 1 回だけ呼ばれること（`internalHandlers.onUpdate` の呼び出し回数 1、`internalHandlers.onDisconnect` の呼び出し回数 0）を固定する。answer SDP は session id と `a=ice-ufrag` と `a=fingerprint` が実行ごとに変わるため全文一致では比較しない。
- `.offer` 経路（`createAndSendAnswer`）: 実 `PeerChannel` と実 `RTCPeerConnection` を作り（既存 helper を使う）、実 `RTCPeerConnection` で生成した有効な offer SDP を含む JSON を `JSONDecoder` で `SignalingOffer` へデコードして `signalingChannel.internalHandlers.onReceive?(.offer(...))` に流す。この経路は `internalHandlers.onUpdate` を呼ばず、WebSocket 未接続のため送信も観測できない。lock が残留していないことは、`.offer` の処理の直後に `peerChannel.disconnect(error:reason:)` を呼び、handler の完了を待って `internalHandlers.onDisconnect` が 1 回呼ばれることで固定する（lock が残留していれば `Lock.waitDisconnect` が遅延パスに入り、`basicDisconnect()` に到達しないため `onDisconnect` は呼ばれない。handler が完了して `lock.unlock()` が呼ばれると、保存された切断要求から `basicDisconnect()` に到達する）。
- `.update` 経路（`createAndSendUpdateAnswer`）: `snapshot.isMultistream` が true のときに処理され、handler の成功経路で `internalHandlers.onUpdate` を呼ぶ。`.reOffer` と同じ方法（実 PC と実 offer SDP）で handler 1 回を固定する。
- `self` 解放経路: handler が `self` を強参照するため現状到達しない。モック・スタブを使わずに `self` を解放済みにして実走させるには、実 `RTCPeerConnection` の完了 block が `PeerChannel` の解放後に呼ばれる順序を作る必要があり、完了のタイミングを制御できないためテストが不安定になる。本 issue では到達可能な経路の handler 呼び出し回数を実測で固定し、この経路はコード（`self` を使わない handler 呼び出し）と排他性の説明で固定する。実装時に安定して実走させる方法（`createAnswer` をテストから呼べる可視性にする等）が見つかった場合はテストを追加し、見つからなかった場合はその理由と代替の検証内容を「解決方法」に記録する。
- `SoraTests` を実行し失敗 0 件であること。`make build`、`make fmt-lint`、`make lint`、`make api-check-fresh` が成功し、公開 API baseline に差分がないこと。

## 完了条件

- `PeerChannel.createAnswer` の `setRemoteDescription` 完了 closure の `guard let self else` 節で、`self` を使わずに `handlerBox` が 1 回呼ばれること。`createAnswer` に handler を呼ばずに return する経路が残っていないこと。
- `.offer` 経路で handler の完了後に `lock` が解放され、`disconnect()` が `basicDisconnect()` に到達すること（`internalHandlers.onDisconnect` が 1 回呼ばれること）。`.reOffer` と `.update` 経路で handler が 1 回だけ呼ばれること。
- `CreateAnswerHandlerBox` の doc コメントの使用契約が「すべての return 経路で厳密に 1 回」に更新され、排他性の根拠が日本語で書かれていること。box に可変状態を追加していないこと。
- コメントに issue 番号が書かれていないこと。
- 追加したテストと既存テストがすべて成功すること。`make build`、`make fmt-lint`、`make lint`、`make api-check-fresh` が成功し、公開 API baseline に差分がないこと。
- `CHANGES.md` の `## develop` の `[FIX]` にエントリが担当者行付きで追加されていること。
