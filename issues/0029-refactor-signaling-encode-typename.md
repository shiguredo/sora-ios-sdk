# Signaling メッセージのエンコード処理を typeName() に統一する

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/refactor-signaling-encode-typename

## 目的

`Signaling` のエンコード処理（`encode(to:)`）で type フィールドの文字列を生成する方法が統一されていない。`reAnswer` のみ `typeName()` を使い、それ以外は `MessageType.<case>.rawValue` を使っている。記述が混在していると手動修正やフォーマット修正の際にどちらへ合わせるべきか判断を誤りやすいため、`typeName()` に一本化してミスを防ぐ。

## 優先度根拠

- 純粋なリファクタリングだが、記述の不統一が原因で過去に実際の不具合が発生しており、再発防止の観点で単なる整理以上の価値がある。
- 一方で機能追加やユーザー影響のあるバグではないため High ではなく Medium とする。

## 現状

`typeName()` は各 case に対応する type 文字列を返し、`re-offer` / `re-answer` などのケバブケースを明示的に返している。

```swift
// Sora/Signaling.swift:153
public func typeName() -> String {
  switch self {
  case .connect:
    return "connect"
  // ...
  case .reOffer:
    return "re-offer"
  case .reAnswer:
    return "re-answer"
  // ...
  }
}
```

一方 `encode(to:)` では、ほとんどの case が `MessageType.<case>.rawValue` を使い、`reAnswer` のみ `typeName()` を使っている。

```swift
// Sora/Signaling.swift:743
public func encode(to encoder: Encoder) throws {
  var container = encoder.container(keyedBy: CodingKeys.self)
  switch self {
  case .connect(let message):
    try container.encode(MessageType.connect.rawValue, forKey: .type)
    try message.encode(to: encoder)
  // ...
  case .reAnswer(let message):
    try container.encode(typeName(), forKey: .type)
    try message.encode(to: encoder)
  // ...
  }
}
```

さらに `enum MessageType` は raw value を指定していないため、ケバブケースの値は `MessageType` 経由では正しく得られない懸念がある。

```swift
// Sora/Signaling.swift:694
enum MessageType: String {
  case connect
  case offer
  case answer
  case update
  case reAnswer
  // ...
}
```

このためエンコード経路が `MessageType.rawValue` と `typeName()` の 2 系統に分かれており、不整合の温床になっている。

## 設計方針

- `encode(to:)` 内のすべての `MessageType.<case>.rawValue` 呼び出しを `typeName()` に置き換え、type 文字列の生成を `typeName()` に一本化する。これにより type 文字列の定義が 1 箇所に集約され、ケバブケースの扱いも `typeName()` の実装に従って一貫する。
- ワイヤー上に出力される type 文字列の値は変更しない。出力 JSON のバイト列が変わらないことを担保する（後方互換性に影響を与えない純粋な内部リファクタリング）。
- `enum MessageType` が `typeName()` 置き換え後にデコード側でも使われていない場合は、参照箇所を確認した上で削除を検討する。デコード処理は type 文字列を直接 switch しているため、`MessageType` が完全に未使用になる可能性が高い。

## 完了条件

- `encode(to:)` 内で type 文字列の生成がすべて `typeName()` に統一されていること。
- エンコード結果の type 文字列が変更前後で完全に一致すること（特に `re-offer` / `re-answer` のケバブケース）。
- `typeName()` 統一に伴い未使用化したコード（`enum MessageType` 等）の扱いを判断し、整理または存置の理由を明確にしていること。
- 既存のテストがすべて通ること。
- `CHANGES.md` の `## develop` セクションに `[FIX]` エントリと担当者行を追記すること。

## 解決方法
