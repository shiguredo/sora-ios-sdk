# Signaling メッセージのエンコード処理を typeName() に統一する

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/refactor-signaling-encode-typename
- Polished: 2026-06-06

## 目的

`Signaling` のエンコード処理（`encode(to:)`）で type フィールドの文字列を生成する方法が統一されていない。`reAnswer` のみ `typeName()` を使い、それ以外は `MessageType.<case>.rawValue` を使っている。`MessageType.reAnswer.rawValue` は "reAnswer"（camelCase）であり、wire 形式の "re-answer"（kebab-case）とは異なるため、誤って `MessageType.rawValue` へ統一した場合にワイヤーフォーマットが壊れる。記述の不統一を `typeName()` に一本化してこのリスクを排除する。

## 優先度根拠

- 記述の不統一が原因で過去に実際の不具合が発生しており、再発防止の観点で単なる整理以上の価値がある。
- 一方で機能追加やユーザー影響のある現行バグではないため High ではなく Medium とする。

## 現状

`typeName()` は各 case の wire 形式文字列を返す（`Sora/Signaling.swift:153`）。`reOffer` → "re-offer"、`reAnswer` → "re-answer" のように kebab-case を明示的に返す。

`encode(to:)`（行 743-772）は以下の case を処理しており、`.reAnswer` のみ `typeName()` を使い、それ以外は `MessageType.<case>.rawValue` を使っている。

```swift
// Sora/Signaling.swift:746-768（変更対象箇所）
case .connect(let message):
  try container.encode(MessageType.connect.rawValue, forKey: .type)  // ← typeName() に変更
case .offer(let message):
  try container.encode(MessageType.offer.rawValue, forKey: .type)    // ← typeName() に変更
case .answer(let message):
  try container.encode(MessageType.answer.rawValue, forKey: .type)   // ← typeName() に変更
case .candidate(let message):
  try container.encode(MessageType.candidate.rawValue, forKey: .type) // ← typeName() に変更
case .update(let message):
  try container.encode(MessageType.update.rawValue, forKey: .type)   // ← typeName() に変更
case .reAnswer(let message):
  try container.encode(typeName(), forKey: .type)                    // ← 変更なし（既に typeName()）
case .pong:
  try container.encode(MessageType.pong.rawValue, forKey: .type)     // ← typeName() に変更
case .disconnect(let message):
  try container.encode(MessageType.disconnect.rawValue, forKey: .type) // ← typeName() に変更
default:
  throw SoraError.invalidSignalingMessage                            // ← 変更なし
```

`enum MessageType`（行 694-706）は `encode(to:)` でのみ参照されており、デコード処理（`init(from decoder:)` 行 716-741）では文字列リテラルで直接 switch しているため `MessageType` を使用していない。

`default` ブランチで throw されるケース（`.notify`/`.ping`/`.push`/`.reOffer`/`.switched` 等）はサーバーがクライアントへ送信するものであり、クライアントがエンコードする必要はない。この非対称性は仕様どおりであり、本 issue では `default` ブランチを変更しない。

## 設計方針

- `encode(to:)` 内の行 747・750・753・756・759・765・767 の各 `MessageType.<case>.rawValue` を `typeName()` に置き換える。`.reAnswer`（行 762）は既に `typeName()` を使っているため変更不要。
- ワイヤー上に出力される type 文字列の値は変更しない。`encode(to:)` で実際に使用されている 7 case については `typeName()` 返値と `MessageType.<case>.rawValue` が一致することを確認済み（connect="connect", offer="offer", answer="answer", candidate="candidate", update="update", pong="pong", disconnect="disconnect"）。なお `MessageType.reAnswer.rawValue` は "reAnswer"（camelCase）であるのに対し `typeName()` は "re-answer"（kebab-case）を返す——この不一致こそが本 issue のリスクの核心であり、`typeName()` への統一で解消される。
- `encode(to:)` の置き換え後、`MessageType` はコードベース全体で完全に未使用になるため、`enum MessageType`（行 694-706）を削除する。デコード側は文字列リテラルで直接 switch しており `MessageType` に依存していない。

## テスト方針

モック・スタブは使用しない。

- 既存の全テストがパスすること（`swift test` または Xcode でテストを実行）。
- エンコードのユニットテストが存在する場合、`re-offer` / `re-answer` のケバブケースが維持されていることを確認すること。存在しない場合は `Signaling.encode(to:)` で type 文字列が変更前後で一致することを手動確認すること。

## 完了条件

- `encode(to:)` 内で type 文字列の生成がすべて `typeName()` に統一されていること（行 747・750・753・756・759・765・767 を変更）。
- エンコード結果の type 文字列が変更前後で完全に一致すること（特に `re-offer` / `re-answer` の kebab-case）。
- `enum MessageType`（行 694-706）が削除されていること。
- 既存のテストがすべて通ること。
- `CHANGES.md` の `## develop` セクションの `### misc` に以下を追記すること（`### misc` セクションが存在しない場合は新設すること）:
  ```
  - [UPDATE] Signaling エンコード処理の type フィールド生成を typeName() に統一する
    - @voluntas
  ```

## 解決方法
