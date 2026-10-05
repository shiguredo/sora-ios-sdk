# `MediaChannel` の解放開始後に `getStats` の完了 block が成功を返し得る問題を修正する

- Created: 2026-09-29
- Completed: {YYYY-MM-DD}
- Priority: Low
- Branch: feature/fix-getstats-after-media-channel-deinit
- Polished: 2026-10-05

## 目的

`MediaChannel` の解放が始まった後に `RTCPeerConnection.statistics` の完了 block が走った場合、統計を成功として handler へ返し得る状態を直す。

変更前は完了 closure が `[weak self]` で `MediaChannel` を捕捉していたため、解放が始まると `self` が nil になり、handler は `MediaChannel is unavailable` の失敗を 1 回受け取っていた。`0177` はこの closure から `MediaChannel` の捕捉を消し、`PeerChannelTransportStorage` への弱参照と `MediaChannelStateStorage` (強参照) で現在の状態を読む形にした。この形では `MediaChannel` の `deinit` の実行中も `peerChannel` (stored property) がまだ生存するため `transportStorage` の弱参照は nil にならず、`stateStorage` は `.connected` のままなので同一性判定を通過し、成功を返す。

## 現状

- `Sora/MediaChannel.swift` の `deinit` は `prepareForDisconnect(error: nil)` と `_peerChannel?.disconnect(error: nil, reason: .user)` を呼ぶ。`prepareForDisconnect` は `state` を変えないため、`deinit` の実行中は `state` が `.connected` のままになる。
- `MediaChannelGetStatsContext` は `handler` / `peerConnection` / `stateStorage` (強参照) / `transportStorage` (弱参照) を保持する。完了 block は `transportStorage` が nil なら失敗を返し、nil でなければ `stateStorage.state == .connected` と `currentPeerConnection === context.peerConnection` を確認して成功を返す。
- Swift の弱参照は解放の開始時 (deinit の実行前) に nil 化される。変更前の `[weak self]` はこの性質に依存して解放開始を検出していた。`0177` の形は `MediaChannel` を捕捉しないため、この検出点を失っている。
- `0177` はこの挙動差を「`MediaChannel` の `deinit` 中に statistics の完了 block が走る狭い窓では、`transportStorage` が生存しているため `MediaChannel is unavailable` ではなく、`stateStorage` が `.connected` のままなら同一性判定を通過して success を返し得る。変更前の `[weak self]` はこの窓でも failure を返していた」と `## 残った懸念` に記録している。
- 窓は狭いが、`MediaChannel` を解放した利用者の handler に、解放済みチャンネルの統計が成功として届き得る。戻り値の `Statistics` は生きている `RTCPeerConnection` から取得した値であり、利用者は「チャンネルが有効な間に取得できた統計」と区別できない。

## 設計方針

- 解放の開始を、完了 block が読む storage へ明示的に記録する。`MediaChannel.deinit` の先頭で `stateStorage` の終端フラグを立て、完了 block が `state == .connected` を確認する前にこのフラグを確認して失敗を返す。
- 判定の追加は `getStats` の完了 block の配送先・呼び出し回数・順序を変えない。失敗は変更前と同じ `SoraError.peerChannelError(reason: "MediaChannel is unavailable")` とし、1 回だけ返す。
- 終端フラグは `MediaChannelStateStorage` の `lock` 配下で読み書きする。`deinit` からの書き込みは `connectionLifecycleLock` を取らず、storage の `lock` だけを使う。取る lock を storage の 1 つに限定することで、lock 順序 (`connectionLifecycleLock` → この storage の一方向) に新しい辺を増やさない。
- `MediaChannel` の解放中に走る別の完了 block (`nativeChannel` を閉じる経路など) の挙動は変えない。本 issue が直すのは `getStats` の完了 block だけである。
- 完了 block から `MediaChannel` 本体を捕捉する形には戻さない (`0177` が消した捕捉を再導入しない)。解放の開始は storage のフラグで伝える。

## 前提となる issue

- `0177` (2026-09-29 完了): `MediaChannelGetStatsContext` の `stateStorage` / `transportStorage` の追加元。本 issue はこの形を保ったまま解放の検出を戻す。
- `0176` (完了 2026-09-29): `getStats` 側の同一性判定の回帰テストと `#if DEBUG` の seam は未実施のまま `0180` へ引き継いだ。本 issue は `0176` の seam を前提にしない。
- `0180` (open): `MediaChannel.state` の単一所有化と、`0176` から引き継いだ `getStats` 側の `#if DEBUG` の seam (`setConnectionStateForTesting(_:)` と `statistics` の完了 block を観測する seam) の追加。本 issue は `0180` の完了後に着手し、`0180` の seam を使ってテストする。seam は `0180` の `state` の書き込み経路に従うため、本 issue では追加しない。完了 block 側の seam は、本 issue のテストで使うため完了 block の判定の先頭 (終端フラグの確認より前) に呼ぶ位置にする (`0180` の同一性判定の回帰テストは、失敗が同一性判定の分岐から返るため、この位置でも成立する)。
- `0120` (open): `MediaChannel` の解放開始後に完了 block が成功を返さないことを snapshot API でも満たすため、本 issue が `MediaChannelStateStorage` に追加する終端フラグを新経路で読む (実装順序は `0179` → `0120`)。フラグの読み出しは `MediaChannelGetStatsContext` が保持する `stateStorage` から行える形にし、`private` に閉じない。
- `0165` (完了 2026-09-28): lock を保持したまま Logger や利用者 handler を呼ばない方針。本 issue もこれに従う。

## 変更対象

- `Sora/MediaChannel.swift`: `MediaChannelStateStorage` への終端フラグの追加、`MediaChannel.deinit` での設定、`getStats` の完了 block での確認、`MediaChannelStateStorage` / `MediaChannelGetStatsContext` / `MediaChannel.stateStorage` の doc (状態の書き込みが `connectionLifecycleLock` 配下に限られるという不変条件と `@unchecked Sendable` の根拠) の更新。`#if DEBUG` の seam は `0180` が追加するものを使い、完了 block 側の seam が判定の先頭 (終端フラグの確認より前) で呼ばれていない場合は本 issue で呼び出し位置を判定の先頭へ移す (`0180` が完了 block 側の seam を追加していない場合は本 issue で追加する。どちらの場合も `0180` の同一性判定の回帰テストが成立することを確認する)。`setConnectionStateForTesting(_:)` は本 issue で追加しない
- `SoraTests/`: `MediaChannel` の解放開始後に完了 block が失敗を返すことの回帰テスト
- `CHANGES.md`: `0177` の `[UPDATE]` エントリから「解放済みチャンネルの統計が成功として返る可能性がある」の記述を削除し、最終状態 (通常の接続経路で利用者の挙動が変わらない) の記述にする。`0177` と本 issue は同じ未リリースの `## develop` にあり、`shiguredo-changelog` の「派生元ブランチとの最終的な差分のみを記載する」「開発ブランチ内の中間状態の修正は記載しない」に従うため、`[FIX]` は追加しない

## テスト方針

モックやスタブは使用しない。検証は Xcode 26.6 と `iphoneos26.5` の環境で行い、版数は着手時点の `Makefile` の `API_XCODE` / `XCODE_SDK` に読み替える。

- `MediaChannel` の解放開始後に `statistics` の完了 block を走らせ、handler が失敗を 1 回だけ受け取ることを固定する。順序は `0180` が追加する `#if DEBUG` の seam (`setConnectionStateForTesting(_:)` と、完了 block の判定の先頭で呼ぶ internal な seam) で確定的に作る (完了 block 側の seam の位置は変更対象のとおり本 issue で揃える)。seam の中で `MediaChannel` の最後の参照を解放して `deinit` で終端フラグを立て、その直後の終端フラグの確認で失敗を返させる (seam が終端フラグの確認より後にあると、確認を通過した後に解放することになり、このテストは成立しない)。`DispatchSemaphore` で完了 block を停止させる方式は、`statistics` が signaling thread の完了を待つ場合に呼び出し元が停止するため使わない (`0176` の判断と同じ)。
- テストは `MediaChannel` の解放後も `PeerChannel` を生存させる。`PeerChannel` も解放されると、終端フラグの確認を削っても既存の `transportStorage` の nil ガードが同じ失敗を返すため、終端フラグの退行を検出できない。
- `SoraTests` 全体を実行し失敗 0 件であること。
- `make build` / `make consumer-build SCHEME=ConsumerCore` / `make api-check-fresh` / `make consumer-check-negative` / `make fmt-lint` / `make lint` が成功すること。
- 退行検出の確認: 終端フラグの確認を削った作業ツリーで追加したテストが失敗することを確認する。確認用の変更は commit しない。

## 完了条件

- `MediaChannel` の解放開始後に `getStats` の完了 block が走った場合、handler が `MediaChannel is unavailable` の失敗を 1 回だけ受け取ること。失敗のメッセージと回数は変更前の `[weak self]` と同じであること (検出点は `deinit` の実行中であり、弱参照が nil 化してから `deinit` 本体が終端フラグを立てるまでの僅かな区間は覆わない)。
- 追加したテストが現行の実装で成功し、終端フラグの確認を削ると失敗すること。
- `getStats` の完了 block が `MediaChannel` を捕捉していないこと (`#SendableClosureCaptures` が増えていないこと)。
- `SoraTests` 全体が失敗 0 件で、`make build` / `make consumer-build SCHEME=ConsumerCore` / `make api-check-fresh` / `make consumer-check-negative` / `make fmt-lint` / `make lint` が成功すること。
- 公開 API のシグネチャと利用者に見える通常の接続経路の挙動が変わっていないこと。`git diff --exit-code -- TestConsumers/Swift6Consumer/ApiBaseline/` が空であること。
- `CHANGES.md` の `## develop` が最終状態だけを記述していること (`0177` の `[UPDATE]` エントリから「解放済みチャンネルの統計が成功として返る可能性がある」の記述が削除され、通常の接続経路で利用者の挙動が変わらない旨だけが残っていること)。

## スコープ外

- `MediaChannel.state` の computed property 化と単一所有への整理。`0180` (open) で扱う。
- `MediaChannel` の解放中に走る `getStats` 以外の完了 block の配送。
- `MediaChannel` への `Sendable` 準拠の追加。
- `0108` の Sora target warnings-as-errors ゲートと `0115` の `Utilities.Stopwatch` の削除。

## 解決方法
