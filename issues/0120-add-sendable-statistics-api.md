# Sendable な statistics snapshot API を追加する

- Created: 2026-08-27
- Completed:
- Branch: feature/add-sendable-statistics-api
- Polished: 2026-10-06

## 目的

WebRTC statistics を actor / Task 境界で安全に受け渡せる、immutable かつ deep Sendable な snapshot API を追加する。

既存の mutable な `Statistics` / `StatisticsEntry` と callback API の source compatibility を維持しながら、Swift 6 の async API が non-Sendable な結果を返さない経路を提供する。

## 現状

`Sora/Statistics.swift` の `Statistics` と `StatisticsEntry` は public class で、stored property がすべて可変である (`Statistics.jsonObject` は get-only の computed property)。

- `Statistics.entries` は mutable array
- `StatisticsEntry.values` は `[String: NSObject]`
- `Statistics.jsonObject` は `Any` を返す

`MediaChannel.getStats()` の async 化は `0058` のスコープ外 (`0058` は「`MediaChannel.getStats()` の async 化: `0120` が担当する」と明記) であり、本 issue が担当する。素朴に `async throws -> Statistics` とすると、actor 境界を越えて mutable class と Objective-C object graph を返すことになる。

## 前提となる issue

- `0058` (open): `MediaChannel.getStats()` の async 化は本 issue が担当すると明記している。
- `0107` (closed 2026-09-24): consumer package と API baseline。本 issue の compile scenario と baseline 更新の前提。
- `0123` (closed 2026-09-15): `Statistics` / `StatisticsEntry` は本 issue の Sendable な snapshot API を受け皿として分類している (原文の「Sendable な snapshot API」は値の写しを指す記述で、本 issue の型名 `StatisticsSnapshot` / `StatisticsEntrySnapshot` と一致する。`0058` / `0157` の「snapshot 型」「snapshot API」も同じ値の性質を指す)。
- `0157` (closed 2026-09-25): `Sora/JSONValue.swift` の `JSONValue` の public 化。値の表現として利用する。
- `0179` (closed 2026-10-05): `MediaChannel` の解放開始後に `getStats` の完了 block が成功を返し得る問題。`0177` (closed 2026-09-29) が導入した `MediaChannelStateStorage` を `0180` (closed 2026-10-05) が接続状態の単一の保持先にし、`0179` がそこに終端フラグ (`isTerminated` / `markTerminated()`) を追加した。`MediaChannel.deinit` の最初の文でフラグを立て、完了 block が `state == .connected` を確認する前に読む形で実装済みである。本 issue の API も同じ `RTCPeerConnection.statistics` の完了 block を入力源にするため、新経路でも同じフラグを読んで終端を判定し、同じ検出機構を本 issue で重複して持たない (`0179` は closed のため本 issue は着手できる)。`0179` が示すとおり deinit 中は `state` が `.connected` のままで、解放開始は状態遷移ではない。`0179` の保証範囲は「完了 block が終端フラグを読んだ時点で `deinit` の最初の文が実行済みの場合」に限られ、フラグの読みがそれに先行した場合は覆えない。本 issue もこの保証範囲に揃え、解放を statistics の完了まで遅延させる方式 (完了 block へ `MediaChannel` の弱参照を足す案) は採らない。

## 設計方針

- immutable な public `StatisticsSnapshot` と `StatisticsEntrySnapshot` を追加し、`Sendable` に準拠させる。property は既存 `Statistics` / `StatisticsEntry` の stored property に対応させ、`StatisticsSnapshot` は `timestamp` と `entries: [StatisticsEntrySnapshot]`、`StatisticsEntrySnapshot` は `id` / `type` / `timestamp` / `values: [String: JSONValue]` を持つ (名前は既存型に合わせ、値の型は `JSONValue` にする)。
- 追加する API は既存 `getStats(handler:)` と同名の overload にしない (`getStats { result in ... }` の解決が曖昧になり source compatibility を壊し得るため)。callback 版は `getStatsSnapshot(handler: @escaping (Result<StatisticsSnapshot, Error>) -> Void)`、async 版は `getStatsSnapshot() async throws -> StatisticsSnapshot` とする。`getStats` と語幹を共有し、戻り値が mutable class (`Statistics`) か immutable な snapshot (`StatisticsSnapshot`) かが名前で分かるようにする。`0109` の `sendableRPC` のような `sendable` 接頭語は使わない (`0109` の counterpart は `SendableRPCResponse` が `RPCResponse` と stored property を同じくする「型制約だけが変わる」もので、呼び出し側の制約を名前で示す必要があった。本 issue の API の差は呼び出し側の制約ではなく返り値の型と性質にあり、`sendable` を付けると「同じ形の Sendable 版」と読めて実態とずれる)。型名は `0102` が値の写しに使った `...Snapshot` に倣い、`Statistics` / `StatisticsEntry` に対応する immutable な値型であることを示す。`StatisticsSnapshot` は `Statistics` の instance を写す意味ではなく、新経路は `RTCStatisticsReport` から直接変換して `Statistics` を経由しない (この点は doc に明記する)。`0110` / `0152` の counterpart の公開名は未定であり、実装時に整合を確認する。
- raw value は `0157` が公開する `Sora/JSONValue.swift` の `JSONValue` (recursive に Sendable な JSON value 型) へ変換する。変換は `JSONValue` の internal な `fromJSONSerializationValue(_:)` へ委譲する (`JSONSerialization.isValidJSONObject` による事前検証を含むため、`Date` や `-inf` の `NSNumber` のように `JSONSerialization` が JSON として受理しない値を渡しても、捕捉できない NSException でプロセスを終了させず捕捉可能な error として扱える。自前の `JSONSerialization.data(withJSONObject:)` 呼び出しで同じ検証を省かない)。`JSONValue` として表現できない値型 (Foundation の JSON 対応外の `NSObject`) を検出した場合は、該当値やエントリーを silent drop せず、その呼び出し全体をエラーとして返す。変換に失敗した場合は、`fromJSONSerializationValue(_:)` が投げた error を `SoraError.mediaChannelError(reason:)` へ写して返す (`SoraError` に新しい case は追加しない。利用者の網羅 switch を壊さないため。既存 `getStats` が返す `peerChannelError` は接続状態と `nativeChannel` の判定用であり、値の変換の失敗には使わない)。
- `NSObject`、`NSDictionary`、`NSArray`、`Any` を `StatisticsSnapshot` / `StatisticsEntrySnapshot` に保持しない。
- `RTCStatisticsReport` の callback executor 上で全 entry を deep copy し、raw WebRTC object を新しい値型の外へ出さない。
- Sendable な値を返す新しい callback / async API を追加し、既存 `getStats(handler:)` のシグネチャと挙動、および `Statistics` は変更しない。
- 既存 `getStats(handler:)` の doc に handler の実行スレッドと Swift 6 言語モードでの書き方を追記する。実行スレッドは経路で異なり、`RTCPeerConnection.statistics` の完了 block から呼ばれる経路 (成功と、完了 block の中の終端フラグ / `state` / `nativeChannel` の同一性判定で失敗する場合) の handler は libwebrtc 側のスレッド、`getStats` の入口の前段判定 (未接続 / `nativeChannel` が nil) で失敗する経路の handler は呼び出し元のスレッドから同期的に呼ばれる (どちらも呼び出し元スレッドは保証されない)。Swift 6 言語モードでの書き方は、handler の中で `first(where:)` などの closure を呼ばず、handler の中の closure に `@Sendable` を付けて Sendable な値へ詰め替えてから main actor / main queue へ渡すか、handler の先頭で main に束ねる (`0118` が、handler の中で closure を呼ぶと MainActor 隔離を継承した closure が WebRTC スレッドで実行時隔離チェックに掛かることを実測している。`@Sendable` を付けるのは handler の中の closure であり、公開 API の handler 引数の型は変えない)。新設する `getStatsSnapshot(handler:)` の doc にも同じ実行スレッドの契約を書く。既存 API の挙動は変更しない。
- `MediaChannel.getStats()` の async 版 (`getStatsSnapshot()`) は `StatisticsSnapshot` を返す設計とし、Task cancellation を `withTaskCancellationHandler` で扱う。`0109` の `rpc` と同じく continuation を 1 回だけ終端するが、`rpc` と違い libwebrtc には統計取得をキャンセルする API が無いため、`onCancel` で取得自体は止められず `RTCPeerConnection.statistics` の完了 block は必ず走る。`onCancel` は lock で保護した箱へ終端済みを記録して continuation を `CancellationError` で 1 回だけ resume するだけにし、完了 block は箱を見て終端済みなら値も失敗も返さず何もしない (`resume` を 2 回行わない)。キャンセルは async 版だけを対象とし、キャンセル・切断・状態遷移・`MediaChannel` の解放開始が競合しても終端は 1 回とする。キャンセルと結果の到着が競合した場合の優先順位は API documentation に記載する。解放開始の検出は `0179` が示す「deinit 中は state が `.connected` のまま」という性質を前提にし、`MediaChannelStateStorage.isTerminated` を新経路でも確認して新経路へ同じ問題を再導入しない。
- legacy API の deprecation と削除は本 issue に含めない。

## 変更対象

- `Sora/Statistics.swift`: immutable な `StatisticsSnapshot` / `StatisticsEntrySnapshot` の追加 (doc には `Statistics` / `StatisticsEntry` と値の型が異なること (`values` が `[String: JSONValue]`) と `jsonObject` 相当を持たないこと、`RTCStatisticsReport` から直接変換して `Statistics` を経由しないことを記す) と、`[String: NSObject]` の値を `JSONValue` へ変換する internal な関数 (`JSONValue.fromJSONSerializationValue(_:)` へ委譲し、失敗を `SoraError.mediaChannelError(reason:)` へ写す)
- `Sora/MediaChannel.swift`: `getStatsSnapshot(handler:)` と `getStatsSnapshot()` の追加 (統計の値型を返す新経路用の context box を持ち、完了 closure は `MediaChannelGetStatsContext` と同じく `MediaChannel` を捕捉しない)、`getStats(handler:)` と `getStatsSnapshot(handler:)` の doc への handler の実行スレッドと Swift 6 言語モードでの書き方の追記、`MediaChannelStateStorage.isTerminated` を新経路で確認する変更 (`0180` が単一所有化した storage と `0179` が追加した終端フラグをそのまま読む)、`#if DEBUG` のテスト用フックを新経路にも追加する変更 (既存 `getStatsWillEvaluateForTesting` は doc が `getStats` 専用と明記しているため流用せず、新経路用の同等のフックを追加する。`getStats` 側のフックの位置・doc・挙動は変えない)
- `SoraTests/`: 値型への変換、actor / Task 境界への受け渡し、変換失敗、キャンセルと各終端の競合のテスト (新規ファイル。ファイル名は実装時に `SoraTests` の既存の命名に合わせる。`#if DEBUG` のテスト用フックに依存するため Debug 構成でのみビルドできる点は `SoraTests/SendableBoxRegressionTests.swift` に合わせる)
- `SoraTests/SendableConformanceTests.swift`: `StatisticsSnapshot` / `StatisticsEntrySnapshot` の `Sendable` 準拠の表明 (`testPublicTypesConformToSendable` の `requireSendable` と、`testValuesCrossActorAndTaskBoundaries` または型ファミリごとの専用メソッドでの actor / Task 境界への受け渡し)
- `TestConsumers/Swift6Consumer/Sources/ConsumerCore/MediaChannelRPC.swift`: callback 版 / async 版 statistics API (`getStatsSnapshot`) の compile scenario の追加
- `TestConsumers/Swift6Consumer/README.md`: statistics の公開 closure の表への `getStatsSnapshot(handler:)` の追加 (表の下の `@Sendable` の有無に関する説明も含む) と、担当表 (`MediaChannelRPC.swift` の行) への statistics 取得 API を追加・変更する作業の追記
- `TestConsumers/Swift6Consumer/ApiBaseline/`: `make api-baseline` による再生成
- `skills/sora-ios-sdk/SKILL.md`: `Sendable` 一覧 (`StatisticsSnapshot` / `StatisticsEntrySnapshot` を `Sendable` へ追加し、legacy の `Statistics` は非 `Sendable` のまま残す)、統計の節、非同期 API の一覧、`## Swift 6 と並行性` の「現状の制約」、`@preconcurrency import Sora` の説明 (「SDK が Sendable な event / statistics API を提供するまでの間」) から statistics を外す更新、クイックリファレンスの更新。「コールバックのスレッド」節の handler bag / `Sora.connect(...)` の引数 handler の executor 契約は `0110` が扱うため、本 issue では触らない
- `CHANGES.md`: `## develop` への `[ADD]` の追記

## テスト方針

モックやスタブは使用しない。

- 実 PeerConnection から statistics を取得し、値型へ変換した後に元の report が解放されても値を読めることを確認する。
- 新しい値型の宣言に `Any` / `NSObject` / raw WebRTC object が現れないことを型宣言と公開 API baseline で確認する。
- 新しい値型を複数 Task と actor 間で受け渡す。
- number、string、bool、sequence、map など実 report に現れる value を変換できることを確認する。
- `JSONValue` へ変換できない value type は実 report に現れないため、値の変換を internal な関数へ切り出し、`@testable import Sora` から JSON 表現できない `NSObject` を与えて、silent drop せず呼び出し全体が `SoraError.mediaChannelError` になることを確認する (モックやスタブは使わない)。
- legacy `Statistics.jsonObject` の値 (`Any`) を `JSONValue.fromJSONSerializationValue(_:)` で `JSONValue` へ正規化し、新しい値型の value と同じ `JSONValue` として比較する (数値を `Double` へ落として比較しない)。`Statistics.jsonObject` の戻り値の型 (`Any`) と内容は変えず、正規化はテスト側で行う。
- キャンセル・切断・状態遷移・`MediaChannel` の解放開始を完了 block の完了と競合させ、終端が 1 回だけであることを確認する。解放開始は `0179` のテストと同じ作りにする (`MediaChannel` の最後の強参照を持つ箱を完了 block の内側で解放し、箱は弱参照で捕捉して解放が起きない場合に `MediaChannel` を延命しない。テスト用フックは終端フラグの確認より前で呼ばれる位置に置き、`PeerChannel` を生存させないと `transportStorage` の nil ガードが同じ失敗を返して終端フラグの退行を検出できない)。
- `0107` の consumer package から callback 版 / async 版の statistics API を利用する。

## 完了条件

- immutable かつ deep Sendable な `StatisticsSnapshot` / `StatisticsEntrySnapshot` が公開されていること。
- `StatisticsSnapshot` / `StatisticsEntrySnapshot` に `Any`、`NSObject`、raw WebRTC object が含まれないこと。
- Sendable な値を返す callback API (`getStatsSnapshot(handler:)`) と async API (`getStatsSnapshot() async throws -> StatisticsSnapshot`) が存在すること。
- 新しい API の終端が、キャンセル・切断・状態遷移・`MediaChannel` の解放開始のどれと競合しても 1 回だけであること。`MediaChannel` の解放開始後に完了 block が走った場合は、成功を返さず `MediaChannel is unavailable` の失敗を 1 回だけ返すこと (保証範囲は `0179` と同じく、完了 block が終端フラグを読んだ時点で `deinit` の最初の文が実行済みの場合に限る。フラグの読みがそれに先行した場合は覆えず、その隙間を閉じるために解放を statistics の完了まで遅延させる方式は採らない)。
- legacy statistics API の source compatibility が維持されていること。
- legacy `getStats(handler:)` と新設する `getStatsSnapshot(handler:)` の doc に handler の実行スレッドと Swift 6 言語モードでの書き方が記載されていること。
- 値型への変換で `JSONValue` へ変換できない value type を検出した場合、silent drop せず `SoraError.mediaChannelError` として返すこと。
- actor / Task 境界で strict concurrency diagnostic が発生しないこと (`0107` の consumer package の gate で確認する)。
- 同じ変更で `make api-baseline` を実行して `TestConsumers/Swift6Consumer/ApiBaseline/` を再生成し、`make api-check-fresh` が成功すること (公開 API の追加は `make api-check` では検出できず、`api-check-fresh` が検出する。`CODEBASE.md` の規約)。
- `skills/sora-ios-sdk/SKILL.md` の `Sendable` 一覧 (`StatisticsSnapshot` / `StatisticsEntrySnapshot` を追加し、legacy の `Statistics` は非 `Sendable` のまま残す)・統計の節・非同期 API の一覧 (`getStatsSnapshot()` を追加)・`## Swift 6 と並行性` の「現状の制約」(statistics を「まだ提供されていない」から外す)・`@preconcurrency import Sora` の説明 (statistics を外す)・クイックリファレンスを Sendable な statistics snapshot API の追加に合わせて更新していること。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
