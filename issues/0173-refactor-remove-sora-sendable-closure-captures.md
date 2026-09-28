# Sora target の `#SendableClosureCaptures` 警告のうち closure と外部 module の型を捕捉する 14 件を解消する

- Created: 2026-09-28
- Completed: {YYYY-MM-DD}
- Priority: Low
- Branch: feature/refactor-remove-sora-sendable-closure-captures
- Polished: 2026-09-28

## 目的

`Sora/` を Swift 6 言語モードで型検査したときに `Sora` target に出る `#SendableClosureCaptures` 警告のうち、捕捉対象が closure と外部 module の型である 14 件を解消する。`0108` の Sora target warnings-as-errors ゲートを塞いでいる要因の 1 つを取り除く。

`0108` のゲートが開くには次の 3 つがすべて解消している必要があり、本 issue は 1 つ目を担う。

- 本 issue の 14 件。うち 6 件 (WebRTC / AVFoundation の型の capture) を解消すると、`0174` が扱う `add '@preconcurrency'` 警告 4 件も同時に消える
- SDK 内部インスタンスの capture 10 件 (スコープ外。別 issue とする)
- `Sora/Utilities.swift` の 1 件 (`0115` の `Stopwatch` 削除待ち。`0115` は非推奨化 release の tag と次期 major version を前提にする pending で、本 issue の完了時点でも残る)

## 現状

2026-09-28 の Xcode 26.6 / Swift 6.3.3 で `Sora/` を型検査した実測は warning 46 件 / error 0 件である (コマンドは「テスト方針」)。内訳は `#SendableClosureCaptures` 25 件、`add '@preconcurrency'` 4 件、`#DeprecatedDeclaration` 17 件。

`#SendableClosureCaptures` 25 件の file 別内訳は `Sora/PeerChannel.swift` 12 / `Sora/MediaChannel.swift` 5 / `Sora/CameraVideoCapturer.swift` 3 / `Sora/NativePeerChannelFactory.swift` 2 / `Sora/ConnectionTimer.swift` 1 / `Sora/DataChannel.swift` 1 / `Sora/Utilities.swift` 1 である。`Sora/Sora.swift` の 1 件は `0155` (完了) が解消済みのため、この 25 件には含まれない。

25 件を捕捉対象の種類で分けると次の 3 群になる。本 issue が扱うのは (A) と (B) の 14 件である。表の行番号は捕捉対象の使用行であり、`swiftc` の一次行も同じ行に出る (closure の開始行ではない)。行番号は 2026-09-28 時点のもので、実装時は再計測する。

| 群 | 件数 | 捕捉対象 | 該当箇所 (診断行) |
| --- | --- | --- | --- |
| A | 8 | 非 `@Sendable` な closure | PeerChannel 1119 / 1158 / 1202 (`handler`)、MediaChannel 1161 (`handler`)、CameraVideoCapturer 1148 / 1216 (`completionHandler`)、NativePeerChannelFactory 312 (`handler`)、ConnectionTimer 112 (`handler`) |
| B | 6 | WebRTC / AVFoundation の型 | PeerChannel 1141 (`RTCSessionDescription`)、1151 (`RTCMediaConstraints`)、1210 (`RTCSessionDescription`)、MediaChannel 1173 (`RTCPeerConnection`)、NativePeerChannelFactory 318 (`RTCPeerConnection`)、CameraVideoCapturer 1146 (`AVCaptureDevice.Format`) |
| C | 10 | SDK 内部の参照型 | PeerChannel 859 / 1110 / 1166 / 1602 / 1728 / 2131 と MediaChannel 733 / 1160 (self)、MediaChannel 733 (`ConnectionTask`)、DataChannel 213 (`DataChannel`) |
| - | 1 | `Utilities.Stopwatch` | Utilities 33 (`0115` の削除で消える) |

- 警告が出るのは、WebRTC / AVFoundation の Objective-C block と `DispatchQueue` / `Timer` の block が `@Sendable` closure として取り込まれるためである。
- (B) の 6 件は、同じ file の `import WebRTC` 行に出る `add '@preconcurrency'` 警告 4 件の原因でもある。(B) の 6 件を code 側で消すと `add '@preconcurrency'` 4 件も消える (2026-09-28 に実測)。本 issue は code 側で消し、`@preconcurrency` は追加しない。
- `0108` のゲート相当の flags を付けた型検査では、`#SendableClosureCaptures` の 25 件と `add '@preconcurrency'` 4 件の計 29 件が error になる (2026-09-28 に実測)。
- `swiftc -typecheck` は最初の error を含む file で打ち切られるため、`-warnings-as-errors` を付けた 1 回の実行では error を全件列挙できない。全件を列挙するときは `-disable-batch-mode -continue-building-after-errors` を付ける。

## 優先度根拠

利用者に見える挙動を変えない refactor であり、本 issue の完了だけでは `0108` のゲートも開かない (SDK 内部インスタンスの capture 10 件と `Sora/Utilities.swift` の 1 件が残る)。一方で `0108` の前提であり、放置すると Sora target のゲートを有効化できないため Low とする。

## 前提となる issue

- `0155` (完了 2026-09-28): `Sora.connect` の設定エラー通知経路の box (`ConnectErrorHandlerBox`)。本 issue はこの box の書き方を前例にする。
- `0115` (pending): `Utilities.Stopwatch` を削除する (`issues/pending/0115-remove-stopwatch.md`)。`Sora/Utilities.swift` の 1 件はこの削除で消える。本 issue は `0115` を待たない。`0115` が先に完了した場合は、本 issue の完了条件の件数を再計測して 1 件減らす。
- `0174`: WebRTC / AVFoundation module 由来の `add '@preconcurrency'` 警告 4 件。本 issue が (B) の 6 件を code 側で消すと `0174` の 4 件も消えるため、`0174` を先に完了させない。実施順は本 issue が先である。
- `0108`: Sora target の warnings-as-errors 化。本 issue の完了が `0108` の前提であり、その逆ではない。
- `0165` (open): `ConnectionTimer.run(timeout:handler:)` を `@discardableResult -> Int` に変え、`MediaChannel.connect` も変更対象にしている。本 issue は `ConnectionTimer.run` の `handler` に box を追加するため、`0165` が完了するまでこの経路に着手しない。
- `0141` (open): `Sora/ConnectionTimer.swift` の `ConnectionMonitor.signalingChannel` の型参照を変更対象にしている。型参照だけの変更であるため、本 issue の後に rebase する。

## 設計方針

- (A) の 8 件は、`init` で確定した closure を保持する用途限定 box (`@unchecked Sendable`) で解消する。box を適用してよいのは、次の 3 つをすべて満たす経路に限る。満たさない経路は box で消さず、スコープ外の C 群と同じ扱いにする。
  - 保持する closure が `init` で確定した `let` であり、box 自身が可変状態を持たないこと
  - その closure は変更前から同じ系統の非同期境界 (WebRTC / AVFoundation の callback、`DispatchQueue`、`Timer` のいずれか) へ渡されており、box は配送先・順序・呼び出し回数を変えず、別系統の境界へ新たに渡すこともないこと
  - box が保持してよいのは closure と、次の 2 つの経路が closure と一緒に保持する `RTCPeerConnection` だけである (`MediaChannel.getStats` の box は `handler` と `peerConnection`、(B) の `NativePeerChannelFactory.createClientOfferSDP` の box は `handler` と `peer2`)。SDK 内部の参照型 `self` / `DataChannel` / `ConnectionTask` は保持しない
- この 3 条件が `0108` の「未完了項目を `@unchecked Sendable` で隠してはならない」に当たらないことの根拠である。判断の目印は「警告が消えること」ではなく「SDK 内部の状態を新たに並行境界へ出すことになっていないこと」とし、経路ごとの根拠を PR に書く。本 issue は C 群 10 件と `Sora/Utilities.swift` の 1 件を残すため、box の追加でゲートを開ける状態にはならない。
- (A) の経路ごとの扱いは次のとおり。
  - `CameraVideoCapturer.startNative` の `completionHandler` (1148) は、既存の `CameraOperationCompletionBox` を使う。ただし同 box の doc コメントは「カメラ操作用の直列 queue へ渡す用途に限定する」と書いており、`startCapture` の完了 block へ渡す用途を含まないため、コメントを「カメラ操作の完了通知を非同期境界へ渡す用途」に広げる。
  - `CameraVideoCapturer.stopNative` の `completionHandler` (1216) は `() -> Void` で既存 box の型 (`(Error?) -> Void`) に合わない。既存 box は `completionBeforeEvent:` の型として 5 箇所から参照されているため汎用化せず、`() -> Void` 用の private な box を追加して `stopNative` の先頭で包む。
  - `PeerChannel.createAnswer` の `handler` (1119 / 1158 / 1202) は、`createAnswer` の先頭で作った 1 つの box で包めば 3 つの非同期 closure と同期経路 (handler を呼ぶすべての経路) を覆う。3 つの closure は同じ `PeerChannel` の呼び出し文脈で逐次に実行され、どの経路も呼び出し後に return するため、使用契約は「高々 1 回だけ呼ばれるが複数の closure から参照される」であり、`0155` の「1 つの block へ 1 回だけ渡す」契約とは書き分ける。handler を渡す呼び出し元の closure が `self` を捕捉している点は、その closure 自身が既に同じ境界を越えている (C 群) ため、box が新しい越境を追加するものではない。
  - `MediaChannel.getStats` の `handler` (1161) は、`peerConnection` を保持する box (後述) に一緒に保持させる。使用契約は `0155` と同じでよい。
  - `NativePeerChannelFactory.createClientOfferSDP` の `handler` (312) は、`peer2` を保持する box (後述) に一緒に保持させる。
  - `ConnectionTimer.run` の `handler` (112) は専用の box で包む。`Timer` block が既に capture している `[weak self]` は変更せず、block の内側で `self.monitors` を読む現在の形も変更しない。
- box のコメントには次を書く。ソースコードに issue 番号は書かない。
  - 安全性の根拠 3 点 (保持する closure は `init` で確定した不変値である・新しい並行性を導入しない・使用契約)
  - `@unchecked Sendable` を付けるのは入れ物だけで、保持する closure とその捕捉状態を `Sendable` にするものではないこと。捕捉状態の同期は、呼び出しスレッドを保証しない既存の挙動の下で利用者の責務であること
  - 実行スレッドの同一性・直列性を契約にしないこと (`0118` の「実行文脈が一致することを契約にしない」)
  - コメントの粒度の前例は `ConnectErrorHandlerBox` (`Sora/Sora.swift`)、参照保持 box の形の前例は `PeerChannelDisconnectCompletionContext` (`Sora/PeerChannel.swift`) である
- (B) の 6 件は `Sendable` な値の capture に置き換える。値の写しができない 2 件は参照保持 box で包む。値の取り出しは、対象の closure に入る前の位置で行う (内側の closure の直前では消えない)。
  - PeerChannel 1141: closure が使うのは `offer.sdpDescription` だけである。`setRemoteDescription` の closure に入る前 (1108 行の `RTCSessionDescription` 生成の直後) に `String` へ取り出す。
  - PeerChannel 1210 と 1214: `localAnswer.sdp` と `localAnswer.sdpDescription` の両方を、`setLocalDescription` の closure に入る前 (1197 行の前) に `String` へ取り出す。片方だけでは 1210 の capture が残る。
  - PeerChannel 1151: closure の内側の `nativeChannel.answer(for: constraints)` の実引数であり、`RTCMediaConstraints` のままでは値の写しができない。`createAnswer` の引数を `RTCMediaConstraints` から `MediaConstraints` (`Sendable`。`nativeValue` は `RTCMediaConstraints` を生成する computed property) へ変え、closure の内側で `constraints.nativeValue` を読む。呼び出し元 4 箇所 (1309 / 1359 / 1408 / 1474) は `updatedConfiguration.constraints` / `currentWebRTCConfiguration().constraints` を渡す形に変える。
  - MediaChannel 1173: `currentPeerConnection === peerConnection` の同一性判定だけに使う。`handler` (1161) と `peerConnection` を `let` で保持する参照保持 box を作り、判定を `currentPeerConnection === context.peerConnection` とする。これは「redirect で旧 `RTCPeerConnection` が入れ替わったことの検出」に必要な強参照を維持するためであり、旧 `RTCPeerConnection` の解放が statistics callback の完了まで遅れることを許容する。`ObjectIdentifier` へ写す案は強参照を失い、callback が呼ばれず handler が返らない挙動変化になり得るため採らない。
  - NativePeerChannelFactory 318: closure の内側で `peer2.close()` を呼ぶため、値の写しができない。`handler` (312) と `peer2` を `let` で保持する参照保持 box を作り、closure の内側で `context.peer2.close()` を呼ぶ。
  - CameraVideoCapturer 1146: ログの文字列補間だけに使う。`format` を `String` にした値だけを closure の外で作り、`device` は closure の内側で参照し続けて `[self]` を残す。メッセージ全体 (`device` を含む) を closure の外で組み立てると `[self]` が未使用になり `capture 'self' was never used [#no-usage]` が出て、本 issue の完了条件が崩れる。既存の `CameraCaptureFormatBox` は「カメラキュー上の `start` に渡す」用途に限定した doc を持つため流用しない。
- 参照保持 box のコメントには、closure 保持 box の 3 点に加えて次を書く。
  - 保持する参照が変更前の closure が capture していた参照と同一であり、参照の解放タイミングを遅らせることの影響 (callback の完了まで旧オブジェクトが残ること) を許容すること
  - callback の実行スレッドと配送が変更前と同じであること
- box の型名は既存の命名 (`ConnectErrorHandlerBox` / `CameraOperationCompletionBox` / `PeerChannelDisconnectCompletionContext`) に揃え、宣言位置は使用する型の近傍とする。
- 既に `Sendable` な型 (`CameraVideoCapturer` は `Sendable`、`ConnectionTimer` / `NativePeerChannelFactory` は `@unchecked Sendable`) へ準拠を追加する作業は含めない。
- 公開 API のシグネチャを変更しない。`createAnswer` と `startNative` / `stopNative` は private であり、追加する box も private のため公開 API baseline に現れない。
- `@Sendable` 化では解消しない。公開 API の closure 引数の型 (`Sora.connect` の handler、`MediaChannel.getStats` の handler、監視 handler) を `@Sendable` にすると利用者の既存コードと公開 API baseline が壊れる (`0110` が legacy handler の型を変えない方針)。
- `CHANGES.md` の `## develop` の主リスト (`[CHANGE]` → `[ADD]` → `[UPDATE]` → `[FIX]` の順) の既存 `[UPDATE]` 群の末尾 (`[FIX]` の直前) に次を追加する。コードブロックの先頭の 2 スペースはこの節の入れ子のためのもので、`CHANGES.md` へはインデントを外して追記する。

  ```
  - [UPDATE] `Sora` の型検査に残る closure capture の `#SendableClosureCaptures` 警告 14 件を解消する
    - 非 `@Sendable` な handler を包む private の box を追加し、WebRTC / AVFoundation の型を capture していた箇所は `Sendable` な値の capture へ置き換える
    - 公開 API と利用者の挙動の変更はない
    - @t-miya
  ```

## スコープ外

- SDK 内部インスタンスの capture 10 件 (C 群)。捕捉対象は `PeerChannel` / `MediaChannel` / `DataChannel` / `ConnectionTask` で、いずれも `Sendable` ではない。用途限定 box で包むのは「SDK 内部の状態を `@unchecked Sendable` で隠す」ことであり `0108` に反するため、捕捉対象の型の状態所有の扱いを決める別 issue とする (本 issue では起票しない)。公開型 `MediaChannel` / `ConnectionTask` に `Sendable` 準拠を含めるかで別 issue のカテゴリと branch が変わる。この 10 件が本 issue と別になる理由は次のとおり。
  - `Sora/PeerChannel.swift` の `isAudioInputInitialized` は宣言 (418)・読み (830)・書き (859、`initializeAudioInput` の `initializeInput` callback 内) のいずれも lock 保護が無く、安全に `Sendable` を主張するには所有者と保護区間を決める必要がある。この決定は `0151` (`PeerChannel.onConnect` の TSan 検出済みデータ競合。open) と `0129` (`PeerChannel.Lock` の統合。open) が同じ状態の所有に触れるため、両者の結論と整合させる必要がある
  - `MediaChannel` は公開型であり、consumer package の負例 (`TestConsumers/Swift6Consumer/NegativeChecks/core-sendable-capture.swift`) が「`Sendable` ではないこと」を固定しているため、`Sendable` 化は公開 API baseline と consumer package の変更を伴う
  - `ConnectionTask` は公開型で、`SoraTests/SendableConformanceTests.swift` は `ConnectionTask.State` だけを対象にしている
  - 参照だけを保持する box の前例 (`WeakMediaChannelBox` / `PeerChannelDisconnectCompletionContext`) はあるが、どちらも捕捉対象の型が既存の排他で守られている範囲に限定した利用であり、C 群 10 件すべてに適用できる根拠にはならない
- `Sora/Utilities.swift` の 1 件 (`0115` の `Stopwatch` 削除)。
- `add '@preconcurrency'` 警告 4 件そのもの (`0174`。本 issue の (B) の解消に伴って消える)。
- `#DeprecatedDeclaration` 警告。`0108` の `.treatWarning("DeprecatedDeclaration", as: .warning)` で warning のまま残す。`0138` は `ICEServerInfo.tlsSecurityPolicy` の内部利用だけを対象にし (`spotlightEnabled` は `0102` で解消済み)、担当の無い deprecation 警告が残る。
- test target の warnings-as-errors ゲート (`0171`)。

## 変更対象

- `Sora/PeerChannel.swift` / `Sora/MediaChannel.swift` / `Sora/CameraVideoCapturer.swift` / `Sora/NativePeerChannelFactory.swift` / `Sora/ConnectionTimer.swift`: (A) 8 件の box と (B) 6 件の値の写し・参照保持 box
- `SoraTests/`: 次の回帰テスト (モックやスタブは使わない)
  - `ConnectionTimer.run` の handler: `ConnectionTimerLifecycleTests.swift` の `makeConnectionTimer` は `.disconnected` の `SignalingChannel` しか作らず handler を発火させないため、`ConnectionMonitor.peerChannel` に `onConnect` を設定した `PeerChannel` (state が `.connecting` になる) を渡す `ConnectionTimer` を作り、timeout 発火で handler が 1 回だけ呼ばれることを `XCTestExpectation` で固定する
  - `PeerChannel.createAnswer` の offer / answer 経路: `PeerChannelRedirectInvalidationTests.swift` の `makePeerChannelWithSignalingChannel` で `PeerChannel` を作り (同 helper は private のため、テストは同じ file に追加する)、`nativeChannel` に実 `RTCPeerConnection` を設定し (`StereoAudioOutputTests.swift` に前例がある)、offer 生成用の実 `RTCPeerConnection` に `createNativeAudioTrack` で audio track を `add` してから `offer(for:)` を呼んで有効な offer SDP を作り、`signalingChannel.internalHandlers.onReceive` から `.reOffer` として流す (media section の無い offer では `setRemoteDescription` が失敗し、m-line の検証も空虚になる)。送信は WebSocket 未接続では行われない (`internalHandlers.onSend` は呼ばれない) ため、観測点は `PeerChannel.internalHandlers.onUpdate` (re-answer 成功経路で answer の SDP とともに呼ばれる) とし、handler の呼び出し回数が 1 回であること、`onUpdate` に渡る SDP が空でないこと、answer の `m=` 行の種別の並びが offer の `m=` 行と一致することを固定する (answer SDP の全文一致は session id / `a=ice-ufrag` / `a=fingerprint` が実行ごとに変わるため使わない)
  - 上記以外の経路は、振る舞いを変えない値の写しと box の追加であるため、型検査と `SoraTests` 全体を回帰の正本にする (`MediaChannel.getStats` は `state` を `.connected` にする経路が private のため単体 harness を作らない)
- `CHANGES.md`: `## develop` の主リストへの `[UPDATE]` の追記
- `issues/0108-update-swiftpm-language-mode.md`: 行番号ではなく現行の文言を目印にして次を直す。`## 前提となる issue` の `- `0173` / `0174`: 残りの `#SendableClosureCaptures` と `add '@preconcurrency'` 4 件 (WebRTC 3 / AVFoundation 1)。` の担当内訳を「`0173` が 14 件 / SDK 内部インスタンスの capture 10 件 (未起票) / `Sora/Utilities.swift` の 1 件 (`0115`)」と書き分け、`add '@preconcurrency'` 4 件は本 issue の (B) 群の解消に伴って消えるため `0174` を担当として挙げない形へ直す。`0157` の重複 bullet の削除、`0155` / `0157` の件数記述、`## 前提となる issue` の導入文、`## 検証方針` の実測値の tree、`## 完了条件` の担当列挙は `0155` 側で更新済みのため、本 issue では扱わない
- `issues/0174-refactor-remove-preconcurrency-import-warnings.md`: 行番号ではなく現行の文言を目印にして、次のいずれかを選んで issue に書く。`0174` の目的 (4 件を解消して `0108` のゲートを有効化できる状態にする) は本 issue の (B) 群の解消で達成されるため、`0174` を close して本 issue に統合するか、`0174` を本 issue の完了後の検証 (4 件が 0 件であることの確認と、`@preconcurrency` を追加しなかった根拠の記録) に縮小する。close する場合は `## スコープ外` の `- `#SendableClosureCaptures` 警告 24 件 (`0173`)。` を実測 (25 件。本 issue 14 件 / SDK 内部インスタンスの capture 10 件 / `Sora/Utilities.swift` の 1 件) に合わせ、`## 解決方法` に「本 issue の (B) 群の解消で 4 件が消えるため対応不要」と実測根拠を書く。縮小する場合は `## 設計方針` / `## 変更対象` / `## 完了条件` にある `CHANGES.md` への `[UPDATE]` 追記の要求 (本 issue のエントリと重複する) と、`0108` の残存警告の担当を `0174` へ更新する要求 (本 issue が書く 3 区分と矛盾する) を外し、`## 前提となる issue` の `0108` の bullet に実施順 (本 issue が先) を追記する

## テスト方針

モックやスタブは使用しない。

- 実装前後の型検査 log を比較する。`build/` は `.gitignore` の対象で fresh な checkout には無いため、log を取る前に `mkdir -p build` を実行し、`-F` には `swift package resolve` が作る xcframework の slice ディレクトリを指定する (fresh な checkout では先に `swift package resolve` を実行する)。実装前の log は同じコマンドの `tee` 先だけを `build/0173-typecheck-before.log` にして実装前に取得する。

  ```
  swiftc -typecheck -swift-version 6 -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -target arm64-apple-ios14.0-simulator \
    -F .build/artifacts/sora-ios-sdk/WebRTC/WebRTC.xcframework/ios-arm64-simulator \
    -module-cache-path build/module-cache $(find Sora -name '*.swift') 2>&1 | tee build/0173-typecheck-after.log
  ```

- 実装後の log で次を確認する。診断は `^<file>:<line>:<col>: warning:` で始まる一次行だけを数える。`#DeprecatedDeclaration` は複数行メッセージの一部が次の行にグループ名を出すため一次行では数えられないが、一次行の総数から `#SendableClosureCaptures` と `add '@preconcurrency'` を引いた値が実装前後とも 17 件であり、下の 3 つの式で一致が確認できる。
  - `#SendableClosureCaptures` が 11 件であること。すべて C 群 (10 件) と `0115` の担当 (`Sora/Utilities.swift`) であり、file 別では PeerChannel 6 / MediaChannel 3 / DataChannel 1 / Utilities 1 になること
  - `add '@preconcurrency'` が 0 件であること
  - 一次行の総数が実装前より 18 件少ないこと (14 件の capture と 4 件の `add '@preconcurrency'` が消える。2026-09-28 の実測では 46 件から 28 件になる)
  - `#no-usage` などの新しい警告が増えていないこと (上の総数で検出する)

  ```
  test "$(grep -cE '^Sora/[^:]+:[0-9]+:[0-9]+: warning:' build/0173-typecheck-after.log)" \
     = "$(($(grep -cE '^Sora/[^:]+:[0-9]+:[0-9]+: warning:' build/0173-typecheck-before.log) - 18))"
  test "$(grep -cE '^Sora/[^:]+:[0-9]+:[0-9]+: warning: .*SendableClosureCaptures' build/0173-typecheck-after.log)" = 11
  test "$(grep -cE "^Sora/[^:]+:[0-9]+:[0-9]+: warning: add '@preconcurrency'" build/0173-typecheck-after.log)" = 0
  ```

- `0108` のゲート相当の flags を付けた型検査で error が 11 件 (C 群 10 件と `Sora/Utilities.swift` の 1 件) だけであること。

  ```
  swiftc -typecheck -disable-batch-mode -continue-building-after-errors \
    -swift-version 6 -warnings-as-errors -Wwarning DeprecatedDeclaration \
    -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
    -target arm64-apple-ios14.0-simulator \
    -F .build/artifacts/sora-ios-sdk/WebRTC/WebRTC.xcframework/ios-arm64-simulator \
    -module-cache-path build/module-cache $(find Sora -name '*.swift') 2>&1 | tee build/0173-gate-after.log
  test "$(grep -cE '^Sora/[^:]+:[0-9]+:[0-9]+: error:' build/0173-gate-after.log)" = 11
  ```

- `0118` の実測のとおり `swiftc` の型検査と実ビルドでは診断集合が一致しないため、`make build` の log でも対象 file の `capture of` 警告が減っていることを確認する。SwiftPM の cache に書き込めない環境では `make build` が依存解決で失敗するため、その場合は `Sora/` の型検査の結果で代替し、その旨を「解決方法」に記録する。
- `SoraTests` を実行し失敗 0 件であること。まず変更した経路のテストだけを回し、その後に全体を回す。E2E は環境変数が無い場合 skip される。
- `make consumer-build SCHEME=ConsumerCore` と `make api-check-fresh` が成功し、`git diff --exit-code -- TestConsumers/Swift6Consumer/ApiBaseline/` が空であること。`make api-baseline` は実行しない (公開 API を変更しないため baseline を再生成しない)。
- `make fmt-lint` と `make lint` が成功すること。

## 完了条件

- `Sora/` の Swift 6 言語モードの型検査で `#SendableClosureCaptures` が 11 件 (C 群 10 件と `Sora/Utilities.swift` の 1 件) になり、`add '@preconcurrency'` が 0 件になり、`#DeprecatedDeclaration` が 17 件のままで、他の警告が増えていないこと。`0108` のゲート相当の flags を付けた型検査の error が 11 件だけであること。
- 追加した box の安全性の根拠 (closure だけを保持する box は 3 条件、`RTCPeerConnection` も保持する box は 3 条件に加えて参照の同一性・解放タイミング・callback の実行スレッド) と、`@unchecked Sendable` が入れ物だけに付くことが日本語コメントで書かれ、コメントに issue 番号が書かれていないこと。値の写しで解消した経路には、その理由が日本語コメントで書かれていること。再利用する `CameraOperationCompletionBox` の doc コメントが新しい用途を含むように更新されていること。
- `grep -rn "@preconcurrency import" Sora/` の結果が空であること。
- `## 変更対象` に書いた `SoraTests` の回帰テストが成功し、`SoraTests` が失敗 0 件であること。`ConnectionTimer` のテストで handler が 1 回だけ呼ばれることと、`PeerChannel.createAnswer` の経路で handler が 1 回だけ呼ばれ、`onUpdate` に空でない SDP が渡り、answer の `m=` 行の種別の並びが offer の `m=` 行と一致することが確認されていること。
- `createAnswer` の回帰 harness を既存 API で構成できないと判明した場合は、型検査を回帰の正本とし、構成できなかった理由と代替の検証内容を「解決方法」に記録していること。
- `make build` の log で対象 file の `capture of` 警告が減っていること。SwiftPM の cache に書き込めない環境では `Sora/` の型検査で代替し、その旨が「解決方法」に記録されていること。
- `make consumer-build SCHEME=ConsumerCore`、`make api-check-fresh`、`make fmt-lint`、`make lint` が成功し、`git diff --exit-code -- TestConsumers/Swift6Consumer/ApiBaseline/` が空であること。
- `CHANGES.md` の `## develop` の主リストの `[UPDATE]` 群の末尾に、`## 設計方針` に書いた文面のエントリが担当者の行 (`- @t-miya`) 付きで追加されていること。
- `issues/0108-update-swiftpm-language-mode.md` と `issues/0174-refactor-remove-preconcurrency-import-warnings.md` が `## 変更対象` に書いた内容に更新されていること。

## 解決方法
