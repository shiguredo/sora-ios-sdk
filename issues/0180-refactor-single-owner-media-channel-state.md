# `MediaChannel.state` を単一の lock 付き storage へ移して単一所有にする

- Created: 2026-09-29
- Completed: {YYYY-MM-DD}
- Priority: Low
- Branch: feature/refactor-single-owner-media-channel-state
- Polished: 2026-10-05

## 目的

`MediaChannel.state` の保持と読み出しを 1 つの lock 付き storage へ集約し、接続状態の所有経路を 1 つにする。

`0177` は `MediaChannel.getStats` の完了 closure から `MediaChannel` の捕捉を消すため、`state` の写しを保持する `MediaChannelStateStorage` を追加した。ただし `state` の公開表現 (`public private(set) var` の stored property) を変えると ABI dump が committed baseline と一致しなくなるため、`state` は stored property のまま残し、`stateStorage` は「完了 closure が読む写し」として併存させた。この形では接続状態の正本が `state` (stored property) に残り、`stateStorage` は `setState(_:)` が同じ区間で更新する写しのままになる。

本 issue はこの従属関係を解消し、`state` を `stateStorage` を読む computed property にして、接続状態の正本を storage 1 つにする。

## 現状

- `Sora/MediaChannel.swift` の `state` は `public private(set) var state: ConnectionState = .disconnected` の stored property であり、`didSet` は無い。`stateStorage` への反映は `setState(_:)` が行う。読みは stored property の getter、`getStats` の完了 closure の読みは `MediaChannelGetStatsContext.stateStorage` と、同じ値を読む経路が 2 つある。
- `state` を書く経路は `setState(_:)` に集約されており、すべて `connectionLifecycleLock` を保持した区間で呼ばれる。`setState(_:)` はその区間で `state` と `stateStorage.state` を同時に更新するため、lock 順序は `connectionLifecycleLock` → `stateStorage` の一方向で保たれている。
- `0177` は「`state` の storage 化は設計の主案 (computed property 化) ではなく、stored property を維持して lock 付き storage を追加する方式へ切り替えた」と記録している。`public private(set) var state` を computed property にすると ABI dump の `declAttributes` (`HasStorage` / `HasInitialValue`) と getter の `Transparent` / `implicit` が変わり、`make api-check-fresh` の fresh な dump が committed baseline と一致しない。`0177` は最小 module でこれを実測して確認し、`make api-baseline` による baseline の再生成を本 issue へ分離した。
- `0176` (完了 2026-09-29) が未実施のまま残した internal な `#if DEBUG` の seam は 2 つある。`setConnectionStateForTesting(_:)` は実接続なしで `.connected` を作り、`getStatsWillEvaluateForTesting` は `getStats` の完了 block の中で呼んで `peerChannel.nativeChannel` の差し替えを確定的に作る (呼び出し位置は設計方針のとおり、本 issue で完了 block の判定の先頭にする)。`0177` はどちらも追加していないため、実装時に本 issue の単一所有の形へ追随させる必要がある。
- `MediaChannelStateStorage` は `MediaChannelGetStatsContext` が強参照で保持し、`getStats` の完了 closure へ渡る。storage 自身は `NSLock` で `state` の読み書きを保護し、`ConnectionState` (値型) だけを保持する。

## 設計方針

- `state` を `stateStorage` を読む computed property にする。`private(set)` は読み取り専用の computed property に付けられない (`'private(set)' modifier cannot be applied to read-only properties`) ため、`public private(set) var state: ConnectionState { get { stateStorage.state } set { setState(newValue) } }` と get / set を明示する。`set` は `setState(_:)` を呼ぶだけで `stateStorage` を直接書かない。公開表現 (アクセスレベルと型) は変えない。
- `state` の書き込みは private メソッド 1 つに集約し、`connectionLifecycleLock` を保持した区間で `stateStorage.state` を書く。`state` は computed property になるため `didSet` を持たない (現行コードにも `didSet` は無い)。`state` への代入は computed property の private setter から `setState(_:)` に入るため、書き込み経路は 1 つのままになる。
- lock 順序は現状の `connectionLifecycleLock` → `stateStorage` の一方向を維持する。`stateStorage` を保持したまま `connectionLifecycleLock` や他の lock を取らない。
- `isAvailable` / `getStats(handler:)` の先頭の確認 / `setAudioHardMute(_:)` / `setAudioSoftMute(_:)` / `requireSenderStreamForVideoMute()`、`Sora/ScreenCapture.swift` の `mediaChannel?.state` など lock の外から読む箇所は、今後も `state` (storage の lock 配下の読み) を使う。`connectionTime` は `connectionStartTime` を読むため対象外である。読みの排他が storage の `NSLock` に揃うことを doc コメントに書く。
- `state` に `didSet` を付けて `stateStorage` の写しを追随させる方式は採らない。観測器を持つ stored property は暗黙の getter から `Transparent` が外れて `make api-check-fresh` の baseline と一致せず (最小 module の ABI probe と実 module で実測。`VideoView.backgroundView` が同じ形である)、`didSet` は `connectionLifecycleLock` を保持したまま Logger を呼び得る。
- 公開 API baseline の再生成を同じ変更に含める。`make api-baseline` を実行し、`git diff TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json` を読んで、差分が `state` の ABI 表現 (`declAttributes` / getter の `Transparent` / `implicit`) の変化だけであり、他の symbol の削除・変更・追加が無いことを確認する。
- `0176` から引き継ぐ internal な `#if DEBUG` の seam は 2 つある。`.connected` を作る `setConnectionStateForTesting(_:)` は本 issue の書き込みメソッド (`setState(_:)`) を通し、`stateStorage` を直接書かない。名前と粒度は `ScreenCapture.setMediaChannelConnectionRequiredForTesting(_:)` に揃える。`getStatsWillEvaluateForTesting` は完了 block の判定の先頭 (後続の `0179` が追加する終端フラグの確認より前) で呼び、`peerChannel.nativeChannel` の差し替えを確定的に作る。宣言と呼び出しの両方を `#if DEBUG` で囲む。`0176` の不一致側テストは、失敗が同一性判定の分岐から返るため、判定の先頭へ置いても成立する。
- `MediaChannel` に `Sendable` 準拠を足さない。`internalHandlers` / `connectionCount` / `publisherCount` / `subscriberCount` などの未整理の可変状態は本 issue でも整理しない (`handlers` は `HandlerStorage` が排他する computed property である)。

## 前提となる issue

- `0177` (2026-09-29 完了): `MediaChannelStateStorage` と `setState(_:)` の追加元。本 issue は `0177` が別 issue へ分離した「`state` の ABI を変えてでも単一所有にする」整理を引き取る。
- `0176` (完了 2026-09-29): `MediaChannel.getStats` の同一性判定の回帰テスト。`createClientOfferSDP` 側は実装済みで、`setConnectionStateForTesting(_:)` と `getStatsWillEvaluateForTesting` の `#if DEBUG` の seam は未実施のまま残した。`0176` から引き継いだ `getStats` 側の seam と回帰テストは本 issue で扱う。`state` を computed property 化して公開 API baseline を再生成する同じ変更で seam を本 issue の書き込み経路へ合わせるのが最も無駄がなく、`0176` はこの引き継ぎでクローズしている。
- `0164` (open): redirect が接続確立前にのみ届くことの調査。`getStats` の同一性判定を E2E で観測できない根拠である。
- `0118` (完了 2026-09-25) と `0171` (完了 2026-09-30): `SoraTests` は Swift 6 言語モードで build され、warnings-as-errors が有効になっている。追加するテストは concurrency 診断を出さない書き方にする。

## 変更対象

- `Sora/MediaChannel.swift`: `state` の computed property 化 (`get` は `stateStorage.state` を読み、`private(set)` の `set` は `setState(_:)` を呼ぶ。`state` は computed property 化しても `didSet` を付けない。現行コードにも `didSet` は無い)、書き込みメソッドの集約、`0176` から引き継いだ `#if DEBUG` の seam 2 つ (`setConnectionStateForTesting(_:)` と、`getStats` の完了 block の判定の先頭で呼ぶ `getStatsWillEvaluateForTesting`) の追加、`state` / `stateStorage` / `MediaChannelStateStorage` / `MediaChannelGetStatsContext` / `setState(_:)` の doc の更新 (「stored property のまま維持する」「`state` の写し」という記述をやめ、`MediaChannelStateStorage` が接続状態の唯一の保持先であることと読み書きの排他を書く)
- `TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json` と `iphoneos26.5.info.txt`: `make api-baseline` による再生成 (同じ変更に含める)
- `SoraTests/`: `state` の読み書きが storage 経由になっても既存テストの観測が変わらないことの確認。`0176` から引き継いだ `getStats` 側の seam と回帰テストは本 issue で扱う
- `CHANGES.md`: `## develop` の主リストへの `[UPDATE]` エントリの追記 (SDK 利用者に影響がある内容だけを書き、公開 API のシグネチャと利用者の挙動が変わらない旨に留める。ABI が変わること・再コンパイルが必要になること・公開 API baseline を再生成することは `CHANGES.md` には書かず本 issue に記載する (`0138` と同じ扱い)。担当者行 `@t-miya` を含める)

## テスト方針

モックやスタブは使用しない。検証は Xcode 26.6 と `iphoneos26.5` の環境で行い、版数は着手時点の `Makefile` の `API_XCODE` / `XCODE_SDK` に読み替える。

- `Sora` target を Swift 6 言語モードで型検査し、`#SendableClosureCaptures` が 0 件のまま (最後の 1 件は `0181` が解消済み。`0115` は `Utilities.Stopwatch` の削除であり警告の有無とは無関係)、新しい診断が増えていないこと。
- `SoraTests` 全体を実行し失敗 0 件であること。`state` の読み書き経路の変更は、`state` を観測する既存テスト (`SoraTests/StereoAudioOutputTests.swift` / `SoraTests/LoggerCallUnderLockTests.swift` / `SoraTests/E2ETestBase.swift` の接続ライフサイクルのテストなど) を含む。`MediaChannel.isAvailable` / `MediaChannel.connectionTime` を観測するテストは現行に無い。
- `make build` と `make consumer-build SCHEME=ConsumerCore` が成功すること。
- `make api-baseline` の後、`git diff TestConsumers/Swift6Consumer/ApiBaseline/` を読み、差分が `state` の ABI 表現だけであることを確認する。続けて `make api-check-fresh` が成功し、`make consumer-check-negative` が成功すること。
- `make fmt-lint` と `make lint` が成功すること。
- 退行検出の確認: `getStats` の完了 block の同一性判定 (`currentPeerConnection === context.peerConnection`) を削った作業ツリーで、不一致側のテスト (seam で `nativeChannel` を差し替えた後に failure を 1 回返すこと) が失敗することを確認する (`0176` の退行検出と同じ形)。`state` の単一所有化後は `state` の書き込みが `stateStorage` を通らない変更を作れない (作れないことが本 issue の成果である)。確認用の変更は commit しない。

## 完了条件

- `Sora/MediaChannel.swift` で接続状態を保持する stored property が `MediaChannelStateStorage` だけになり、`state` がそれを読む computed property になっていること (`get` は `stateStorage.state` を読み、`private(set)` の `set` は `setState(_:)` を呼ぶ)。`state` に `didSet` を付けないこと (`stateStorage` への反映は `setState(_:)` の 1 箇所に閉じること)。
- `state` を書く経路が 1 つの private メソッドに集約され、その呼び出しがすべて `connectionLifecycleLock` を保持した区間にあること (lock 順序 `connectionLifecycleLock` → `stateStorage` の一方向)。
- 公開 API のアクセスレベルと型 (`public private(set)` の `ConnectionState`) が変わっていないこと。`make api-check-fresh` が成功し、baseline の差分が `state` ノード内に限られること (`declAttributes` の `HasStorage` / `HasInitialValue` と `hasStorage`、getter の `implicit` / `Transparent` の消失。`SetterAccess` と `Final`、USR、`mangledName` は変わらない)。
- `state` / `stateStorage` / `MediaChannelStateStorage` / `MediaChannelGetStatsContext` / `setState(_:)` の doc から「stored property のまま維持する」「`state` の写し」という記述が消え、`MediaChannelStateStorage` が接続状態の唯一の保持先であることと読み書きの排他が書かれていること。
- `SoraTests` 全体が失敗 0 件で、`make build` / `make consumer-build SCHEME=ConsumerCore` / `make consumer-check-negative` / `make fmt-lint` / `make lint` が成功すること。
- `0176` から引き継いだ `getStats` 側の seam 2 つ (`setConnectionStateForTesting(_:)` と `getStatsWillEvaluateForTesting`) と `getStats` の同一性判定の回帰テスト (同じ `RTCPeerConnection` なら success、seam で差し替えた後は failure を 1 回返すことの両方) を追加すること。`setConnectionStateForTesting(_:)` は本 issue の書き込み経路を通し、`stateStorage` を直接書かないこと。
- `CHANGES.md` の `## develop` に `[UPDATE]` エントリが担当者行付きで追加されていること。

## スコープ外

- `MediaChannel` の解放開始後に `getStats` の完了 block が success を返し得る挙動差。`0177` で生じた別目的の不具合であり、`0179` (open) で扱う。
- `MediaChannel.internalHandlers` / `connectionStartTime` / `connectionCount` / `publisherCount` / `subscriberCount` など、`state` 以外の `MediaChannel` の可変状態の整理 (`handlers` は `HandlerStorage` が排他済みである)。
- `MediaChannel` への `Sendable` 準拠の追加。
- `0108` の Sora target warnings-as-errors ゲートと `0115` の `Utilities.Stopwatch` の削除。

## 解決方法
