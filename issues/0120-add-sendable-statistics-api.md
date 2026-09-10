# Sendable な statistics snapshot API を追加する

- Created: 2026-08-27
- Completed:
- Branch: feature/add-sendable-statistics-api
- Polished:

## 目的

WebRTC statistics を actor / Task 境界で安全に受け渡せる、immutable かつ deep Sendable な snapshot API を追加する。

既存の mutable な `Statistics` / `StatisticsEntry` と callback API の source compatibility を維持しながら、Swift 6 の async API が non-Sendable な結果を返さない経路を提供する。

## 現状

`Sora/Statistics.swift` の `Statistics` と `StatisticsEntry` は public class で、全 property が可変である。

- `Statistics.entries` は mutable array
- `StatisticsEntry.values` は `[String: NSObject]`
- `Statistics.jsonObject` は `Any` を返す

`0058` は `MediaChannel.getStats()` の async 版を `async throws -> Statistics` として追加する設計だが、actor 境界を越えて mutable class と Objective-C object graph を返すことになる。

## 設計方針

- immutable な public `StatisticsSnapshot` と `StatisticsEntrySnapshot` を追加し、`Sendable` に準拠させる。
- raw value は recursive に Sendable な JSON value、または型を限定した statistics value enum へ変換する。
- `NSObject`、`NSDictionary`、`NSArray`、`Any` を snapshot に保持しない。
- `RTCStatisticsReport` の callback executor 上で全 entry を deep copy し、raw WebRTC object を snapshot の外へ出さない。
- snapshot を返す新しい callback / async API を追加し、既存 `getStats(handler:)` と `Statistics` は変更しない。
- `0058` の async API は cancellation と exactly-once を扱う設計へ更新し、新 snapshot API を利用する。
- legacy API の deprecation と削除は本 issue に含めない。

## テスト方針

モックやスタブは使用しない。

- 実 PeerConnection から statistics を取得し、snapshot 変換後に元の report が解放されても値を読めることを確認する。
- snapshot を複数 Task と actor 間で受け渡す。
- number、string、bool、sequence、map など実 report に現れる value を変換できることを確認する。
- 未対応の value type を検出した場合の方針を明示し、silent drop しない。
- legacy `Statistics.jsonObject` と新 snapshot の JSON 表現を、表現可能な既存 field で比較する。
- `0107` の consumer fixture から async statistics API を利用する。

## 完了条件

- immutable かつ deep Sendable な statistics snapshot 型が公開されていること。
- snapshot に `Any`、`NSObject`、raw WebRTC object が含まれないこと。
- snapshot を返す callback API と async API が存在すること。
- legacy statistics API の source compatibility が維持されていること。
- actor / Task 境界で strict concurrency diagnostic が発生しないこと。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
