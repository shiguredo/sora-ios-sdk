# Sendable な statistics snapshot API を追加する

- Created: 2026-08-27
- Completed:
- Branch: feature/add-sendable-statistics-api
- Polished: 2026-10-05

## 目的

WebRTC statistics を actor / Task 境界で安全に受け渡せる、immutable かつ deep Sendable な snapshot API を追加する。

既存の mutable な `Statistics` / `StatisticsEntry` と callback API の source compatibility を維持しながら、Swift 6 の async API が non-Sendable な結果を返さない経路を提供する。

## 現状

`Sora/Statistics.swift` の `Statistics` と `StatisticsEntry` は public class で、全 property が可変である。

- `Statistics.entries` は mutable array
- `StatisticsEntry.values` は `[String: NSObject]`
- `Statistics.jsonObject` は `Any` を返す

`MediaChannel.getStats()` の async 化は `0058` のスコープ外 (`0058` は「`MediaChannel.getStats()` の async 化: `0120` が担当する」と明記) であり、本 issue が担当する。素朴に `async throws -> Statistics` とすると、actor 境界を越えて mutable class と Objective-C object graph を返すことになる。

## 前提となる issue

- `0058` (open): `MediaChannel.getStats()` の async 化は本 issue が担当すると明記している。
- `0107` (完了 2026-09-24): consumer package と API baseline。本 issue の compile scenario と baseline 更新の前提。
- `0123` (完了 2026-09-15): `Statistics` / `StatisticsEntry` は本 issue の snapshot API を受け皿として分類している。
- `0157` (実装済み): `Sora/JSONValue.swift` の `JSONValue` の public 化。snapshot の値の表現として利用する。
- `0179` (open): `MediaChannel` の解放開始後に `getStats` の完了 block が成功を返し得る問題。snapshot API も同じ `RTCPeerConnection.statistics` の完了 block を入力源にするため、解放開始の検出と終端の設計を `0179` と整合させる (`0179` が示すとおり、deinit 中は `state` が `.connected` のままで、解放開始は状態遷移ではない)。実装順序は `0179` を先とし、本 issue は `0179` の完了後に着手する。`0179` が `MediaChannelStateStorage` に追加する終端フラグを新経路でも確認し、同じ検出機構を本 issue で重複して持たない。

## 設計方針

- immutable な public `StatisticsSnapshot` と `StatisticsEntrySnapshot` を追加し、`Sendable` に準拠させる。
- 追加する API は既存 `getStats(handler:)` と同名の overload にしない (`getStats { result in ... }` の解決が曖昧になり source compatibility を壊し得るため)。callback 版は `getStatistics(handler: @escaping (Result<StatisticsSnapshot, Error>) -> Void)`、async 版は `getStatistics() async throws -> StatisticsSnapshot` とする。
- raw value は `0157` が公開する `Sora/JSONValue.swift` の `JSONValue` (recursive に Sendable な JSON value 型) へ変換する。`JSONValue` として表現できない値型 (Foundation の JSON 対応外の `NSObject`) を検出した場合は、該当値やエントリーを silent drop せず、その呼び出し全体をエラーとして返す。変換に失敗した場合は `SoraError.mediaChannelError(reason:)` を返す (`SoraError` に新しい case は追加しない。利用者の網羅 switch を壊さないため。既存 `getStats` が返す `peerChannelError` は接続状態と `nativeChannel` の判定用であり、値の変換の失敗には使わない)。
- `NSObject`、`NSDictionary`、`NSArray`、`Any` を snapshot に保持しない。
- `RTCStatisticsReport` の callback executor 上で全 entry を deep copy し、raw WebRTC object を snapshot の外へ出さない。
- snapshot を返す新しい callback / async API を追加し、既存 `getStats(handler:)` のシグネチャと挙動、および `Statistics` は変更しない。
- 既存 `getStats(handler:)` の doc に、handler が libwebrtc のスレッドから呼ばれることと Swift 6 言語モードでの書き方を追記する (handler の中で `first(where:)` などの closure を呼ばず、closure に `@Sendable` を付けて Sendable な値へ詰め替えてから main actor / main queue へ渡すか、handler の先頭で main に束ねる。handler の中で closure を呼ぶと実行時隔離チェックで落ちることを実測済み)。既存 API の挙動は変更しない。
- `MediaChannel.getStats()` の async 版 (`getStatistics()`) は新 snapshot API を返す設計とし、Task cancellation を `withTaskCancellationHandler` で扱う (`0109` の `rpc` と同じ形)。キャンセルは async 版だけを対象とし、キャンセル・切断・状態遷移・`MediaChannel` の解放開始が競合しても終端は 1 回とする。キャンセル時は `CancellationError` で終端し、`RTCPeerConnection.statistics` の完了 block が遅れて届いても値は返さない (終端済みかどうかを lock で保護した箱で判定し、`resume` を 2 回行わない)。キャンセルと結果の到着が競合した場合の優先順位は API documentation に記載する。解放開始の検出は `0179` が示す「deinit 中は state が `.connected` のまま」という性質を前提にし、`0179` の終端フラグを新経路でも確認して新経路へ同じ問題を再導入しない。
- legacy API の deprecation と削除は本 issue に含めない。

## 変更対象

- `Sora/Statistics.swift`: immutable な `StatisticsSnapshot` / `StatisticsEntrySnapshot` の追加と、`[String: NSObject]` の値を `JSONValue` へ変換する internal な関数
- `Sora/MediaChannel.swift`: `getStatistics(handler:)` と `getStatistics()` の追加、`getStats(handler:)` の doc への handler の実行スレッドと Swift 6 言語モードでの書き方の追記、`0179` の終端フラグを新経路で確認する変更
- `SoraTests/`: snapshot の値の変換、actor / Task 境界への受け渡し、変換失敗、キャンセルと各終端の競合のテスト (新規ファイル。ファイル名は実装時に `SoraTests` の既存の命名に合わせる)
- `TestConsumers/Swift6Consumer/Sources/ConsumerCore/MediaChannelRPC.swift`: callback 版 / async 版 statistics API の compile scenario の追加
- `TestConsumers/Swift6Consumer/README.md`: statistics の公開 closure の表と担当表の更新
- `TestConsumers/Swift6Consumer/ApiBaseline/`: `make api-baseline` による再生成
- `skills/sora-ios-sdk/SKILL.md`: `Sendable` 一覧、統計の節、非同期 API の一覧、`## Swift 6 と並行性` の「現状の制約」、クイックリファレンスの更新
- `CHANGES.md`: `## develop` への `[ADD]` の追記

## テスト方針

モックやスタブは使用しない。

- 実 PeerConnection から statistics を取得し、snapshot 変換後に元の report が解放されても値を読めることを確認する。
- snapshot 型の宣言に `Any` / `NSObject` / raw WebRTC object が現れないことを型宣言と公開 API baseline で確認する。
- snapshot を複数 Task と actor 間で受け渡す。
- number、string、bool、sequence、map など実 report に現れる value を変換できることを確認する。
- `JSONValue` へ変換できない value type は実 report に現れないため、値の変換を internal な関数へ切り出し、`@testable import Sora` から JSON 表現できない `NSObject` を与えて、silent drop せず呼び出し全体が `SoraError.mediaChannelError` になることを確認する (モックやスタブは使わない)。
- legacy `Statistics.jsonObject` の値を snapshot と同じ変換経路で `JSONValue` へ正規化し、snapshot の value と `JSONValue` として比較する (数値を `Double` へ落として比較しない)。
- キャンセル・切断・状態遷移・`MediaChannel` の解放開始を完了 block の完了と競合させ、終端が 1 回だけであることを確認する (解放開始の作り方は `0179` のテスト方針に揃える)。
- `0107` の consumer package から callback 版 / async 版の statistics API を利用する。

## 完了条件

- immutable かつ deep Sendable な statistics snapshot 型が公開されていること。
- snapshot に `Any`、`NSObject`、raw WebRTC object が含まれないこと。
- snapshot を返す callback API (`getStatistics(handler:)`) と async API (`getStatistics() async throws -> StatisticsSnapshot`) が存在すること。
- snapshot API の終端が、キャンセル・切断・状態遷移・`MediaChannel` の解放開始のどれと競合しても 1 回だけであること。`MediaChannel` の解放開始後に完了 block が走った場合は、成功を返さず `MediaChannel is unavailable` の失敗を 1 回だけ返すこと。
- legacy statistics API の source compatibility が維持されていること。
- legacy `getStats(handler:)` の doc に handler の実行スレッドと Swift 6 言語モードでの書き方が記載されていること。
- snapshot の値の変換で `JSONValue` へ変換できない value type を検出した場合、silent drop せず `SoraError.mediaChannelError` として返すこと。
- actor / Task 境界で strict concurrency diagnostic が発生しないこと (`0107` の consumer package の gate で確認する)。
- 同じ変更で `make api-baseline` を実行して `TestConsumers/Swift6Consumer/ApiBaseline/` を再生成し、`make api-check-fresh` が成功すること (公開 API の追加は `make api-check` では検出できず、`api-check-fresh` が検出する。`CODEBASE.md` の規約)。
- `skills/sora-ios-sdk/SKILL.md` の `Sendable` 一覧・統計の節・非同期 API の一覧・`## Swift 6 と並行性` の「現状の制約」を snapshot API の追加に合わせて更新していること (statistics を「まだ提供されていない」から外す)。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
