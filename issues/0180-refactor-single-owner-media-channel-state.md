# `MediaChannel.state` を単一の lock 付き storage へ移して単一所有にする

- Created: 2026-09-29
- Completed: {YYYY-MM-DD}
- Priority: Low
- Branch: feature/refactor-single-owner-media-channel-state
- Polished: {YYYY-MM-DD}

## 目的

`MediaChannel.state` の保持と読み出しを 1 つの lock 付き storage へ集約し、接続状態の所有経路を 1 つにする。

`0177` は `MediaChannel.getStats` の完了 closure から `MediaChannel` の捕捉を消すため、`state` の写しを保持する `MediaChannelStateStorage` を追加した。ただし `state` の公開表現 (`public private(set) var` の stored property) を変えると ABI dump が committed baseline と一致しなくなるため、`state` は stored property のまま残し、`stateStorage` は「完了 closure が読む写し」として併存させた。この形では接続状態の正本が `state` に残り、`stateStorage` は `state` の `didSet` で追随する従属値になる。

本 issue はこの従属関係を解消し、`state` を `stateStorage` を読む computed property にして、接続状態の正本を storage 1 つにする。

## 現状

- `Sora/MediaChannel.swift` の `state` は `public private(set) var state: ConnectionState = .disconnected` の stored property であり、`didSet` が `stateStorage.state = state` で写しを追随させる。読みは stored property の getter、`getStats` の完了 closure の読みは `MediaChannelGetStatsContext.stateStorage` と、同じ値を読む経路が 2 つある。
- `state` を書く経路は `setState(_:)` に集約されており、すべて `connectionLifecycleLock` を保持した区間で呼ばれる。`state` の `didSet` がその区間で `stateStorage` の lock を取るため、lock 順序は `connectionLifecycleLock` → `stateStorage` の一方向で保たれている。
- `0177` は「`state` の storage 化は設計の主案 (computed property 化) ではなく、stored property を維持して lock 付き storage を追加する方式へ切り替えた」と記録している。`public private(set) var state` を computed property にすると ABI dump の `declAttributes` (`HasStorage` / `HasInitialValue`) と getter の `Transparent` / `implicit` が変わり、`make api-check-fresh` の fresh な dump が committed baseline と一致しない。`0177` は最小 module でこれを実測して確認し、`make api-baseline` による baseline の再生成を本 issue へ分離した。
- `0176` (open) が追加を予定する `setConnectionStateForTesting(_:)` は `#if DEBUG` の seam で `.connected` を作る。`0177` はこの seam を追加していないため、実装時に本 issue の単一所有の形へ追随させる必要がある。
- `MediaChannelStateStorage` は `MediaChannelGetStatsContext` が強参照で保持し、`getStats` の完了 closure へ渡る。storage 自身は `NSLock` で `state` の読み書きを保護し、`ConnectionState` (値型) だけを保持する。

## 設計方針

- `state` を `stateStorage` を読む computed property にする。公開表現は `public private(set) var state: ConnectionState` のままとし、getter の実装だけを `stateStorage.state` に置き換える。
- `state` の書き込みは private メソッド 1 つに集約し、`connectionLifecycleLock` を保持した区間で `stateStorage.state` を書く。`state` の `didSet` は削除する (computed property には付けられない)。
- lock 順序は現状の `connectionLifecycleLock` → `stateStorage` の一方向を維持する。`stateStorage` を保持したまま `connectionLifecycleLock` や他の lock を取らない。
- `isAvailable` と `connectionTime` など lock の外から読む箇所は、今後も `state` (storage の lock 配下の読み) を使う。読みの排他が storage の `NSLock` に揃うことを doc コメントに書く。
- `state` に `didSet` を付けて `stateStorage` の写しを追随させる方式は採らない。観測器を持つ stored property は暗黙の getter から `Transparent` が外れて ABI dump が変わり、`make api-check-fresh` が差分を報告する (最小 module の ABI probe で実測。`VideoView.backgroundView` が同じ形である)。`state` を computed property にして storage を読む形にすれば、この `Transparent` の差も含めて baseline を再生成する。
- 公開 API baseline の再生成を同じ変更に含める。`make api-baseline` を実行し、`git diff TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json` を読んで、差分が `state` の ABI 表現 (`declAttributes` / getter の `Transparent` / `implicit`) の変化だけであり、他の symbol の削除・変更・追加が無いことを確認する。
- `0176` の `setConnectionStateForTesting(_:)` は追加時に本 issue の書き込みメソッドを通し、`stateStorage` を直接書かない。名前と粒度は `ScreenCapture.setMediaChannelConnectionRequiredForTesting(_:)` に揃える。
- `MediaChannel` に `Sendable` 準拠を足さない。`handlers` / `internalHandlers` / `connectionCount` / `publisherCount` / `subscriberCount` などの未整理の可変状態は本 issue でも整理しない。

## 前提となる issue

- `0177` (2026-09-29 完了): `MediaChannelStateStorage` と `setState(_:)` の追加元。本 issue は `0177` が別 issue へ分離した「`state` の ABI を変えてでも単一所有にする」整理を引き取る。
- `0176` (open): `MediaChannel.getStats` の同一性判定の回帰テスト。`setConnectionStateForTesting(_:)` と `#if DEBUG` の seam を追加する。本 issue は `0176` の seam を追加しないが、`0176` が本 issue の書き込み経路へ追随できる形にする。
- `0164` (open): redirect が接続確立前にのみ届くことの調査。`getStats` の同一性判定を E2E で観測できない根拠である。
- `0118` (完了 2026-09-25) と `0171` (open): `SoraTests` は Swift 6 言語モードで build され、`0171` の完了後は warnings-as-errors になる。追加するテストは concurrency 診断を出さない書き方にする。

## 変更対象

- `Sora/MediaChannel.swift`: `state` の computed property 化、`stateStorage` を読む getter、書き込みメソッドの集約、`state` の `didSet` の削除、関連する doc コメントの更新
- `TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json` と `iphoneos26.5.info.txt`: `make api-baseline` による再生成 (同じ変更に含める)
- `SoraTests/`: `state` の読み書きが storage 経由になっても既存テストの観測が変わらないことの確認。`0176` の seam は本 issue では追加しない
- `CHANGES.md`: `## develop` への `[UPDATE]` エントリの追記 (公開 API のシグネチャは変わらず、ABI baseline の再生成を伴う内部整理であることを補足する。担当者行 `@t-miya` を含める)

## テスト方針

モックやスタブは使用しない。検証は Xcode 26.6 と `iphoneos26.5` の環境で行い、版数は着手時点の `Makefile` の `API_XCODE` / `XCODE_SDK` に読み替える。

- `Sora` target を Swift 6 言語モードで型検査し、`#SendableClosureCaptures` が `Sora/Utilities.swift` の `Utilities.Stopwatch` の 1 件 (`0115` 完了済みなら 0 件) のままで、新しい診断が増えていないこと。
- `SoraTests` 全体を実行し失敗 0 件であること。`state` の読み書き経路の変更は既存テストの観測対象 (`isAvailable` / `connectionTime` / 接続ライフサイクルのテスト) を含む。
- `make build` と `make consumer-build SCHEME=ConsumerCore` が成功すること。
- `make api-baseline` の後、`git diff TestConsumers/Swift6Consumer/ApiBaseline/` を読み、差分が `state` の ABI 表現だけであることを確認する。続けて `make api-check-fresh` が成功し、`make consumer-check-negative` が成功すること。
- `make fmt-lint` と `make lint` が成功すること。
- 退行検出の確認: `state` の書き込みが `stateStorage` を通らない変更を入れると、`getStats` の同一性判定のテスト (`0176` が追加するもの) が失敗することを確認する。確認用の変更は commit しない。

## 完了条件

- `Sora/MediaChannel.swift` で接続状態を保持する stored property が `MediaChannelStateStorage` だけになり、`state` がそれを読む computed property になっていること。`state` の `didSet` が残っていないこと。
- `state` を書く経路が 1 つの private メソッドに集約され、その呼び出しがすべて `connectionLifecycleLock` を保持した区間にあること (lock 順序 `connectionLifecycleLock` → `stateStorage` の一方向)。
- 公開 API のシグネチャ (`public private(set) var state: ConnectionState`) が変わっていないこと。`make api-check-fresh` が成功し、baseline の差分が `state` の ABI 表現だけであること。
- `SoraTests` 全体が失敗 0 件で、`make build` / `make consumer-build SCHEME=ConsumerCore` / `make consumer-check-negative` / `make fmt-lint` / `make lint` が成功すること。
- `0176` の `setConnectionStateForTesting(_:)` を本 issue の書き込み経路で実装できる形になっていること (本 issue では seam を追加しない)。
- `CHANGES.md` の `## develop` に `[UPDATE]` エントリが担当者行付きで追加されていること。

## スコープ外

- `MediaChannel` の解放開始後に `getStats` の完了 block が success を返し得る挙動差。`0177` で生じた別目的の不具合であり、別 issue で扱う。
- `0176` が追加する `setConnectionStateForTesting(_:)` と `#if DEBUG` の seam、`getStats` の同一性判定の回帰テスト。本 issue は実装が追随できる形にするだけで、テストは追加しない。
- `MediaChannel.handlers` / `internalHandlers` / `connectionStartTime` / `connectionCount` / `publisherCount` / `subscriberCount` など、`state` 以外の `MediaChannel` の可変状態の整理。
- `MediaChannel` への `Sendable` 準拠の追加。
- `0108` の Sora target warnings-as-errors ゲートと `0115` の `Utilities.Stopwatch` の削除。

## 解決方法
