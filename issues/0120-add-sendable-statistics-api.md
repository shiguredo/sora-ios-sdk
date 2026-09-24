# Sendable な statistics snapshot API を追加する

- Created: 2026-08-27
- Completed:
- Branch: feature/add-sendable-statistics-api
- Polished: 2026-09-24

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
- `0157` (open): `Sora/JSONValue.swift` の `JSONValue` の public 化。snapshot の値の表現として利用する。本 issue の実装は `0157` の完了を前提とする (未完了の場合は先に完了させる)。

## 設計方針

- immutable な public `StatisticsSnapshot` と `StatisticsEntrySnapshot` を追加し、`Sendable` に準拠させる。
- raw value は `0157` が公開する `Sora/JSONValue.swift` の `JSONValue` (recursive に Sendable な JSON value 型) へ変換する。`JSONValue` として表現できない値型 (Foundation の JSON 対応外の `NSObject`) を検出した場合は、該当値やエントリーを silent drop せず、その呼び出し全体をエラーとして返す。
- `NSObject`、`NSDictionary`、`NSArray`、`Any` を snapshot に保持しない。
- `RTCStatisticsReport` の callback executor 上で全 entry を deep copy し、raw WebRTC object を snapshot の外へ出さない。
- snapshot を返す新しい callback / async API を追加し、既存 `getStats(handler:)` と `Statistics` は変更しない。
- `MediaChannel.getStats()` の async 版は新 snapshot API を返す設計とし、cancellation と exactly-once (キャンセル・切断・状態遷移が競合しても終端が 1 回だけ) を扱う。
- legacy API の deprecation と削除は本 issue に含めない。

## テスト方針

モックやスタブは使用しない。

- 実 PeerConnection から statistics を取得し、snapshot 変換後に元の report が解放されても値を読めることを確認する。
- snapshot を複数 Task と actor 間で受け渡す。
- number、string、bool、sequence、map など実 report に現れる value を変換できることを確認する。
- `JSONValue` へ変換できない value type を検出した場合、silent drop せず呼び出し全体がエラーになることを確認する。
- legacy `Statistics.jsonObject` と新 snapshot の JSON 表現を、表現可能な既存 field で比較する。
- `0107` の consumer package から async statistics API を利用する。

## 完了条件

- immutable かつ deep Sendable な statistics snapshot 型が公開されていること。
- snapshot に `Any`、`NSObject`、raw WebRTC object が含まれないこと。
- snapshot を返す callback API と async API が存在すること。
- legacy statistics API の source compatibility が維持されていること。
- snapshot の値の変換で `JSONValue` へ変換できない value type を検出した場合、silent drop せずエラーとして返すこと。
- actor / Task 境界で strict concurrency diagnostic が発生しないこと。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
