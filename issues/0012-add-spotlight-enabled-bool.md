# spotlightEnabled を Bool で設定できるようにする

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-spotlight-enabled-bool

## 目的

有効 / 無効を表す設定で `Bool` と `Enum` が混在しており紛らわしい。`simulcastEnabled` は `Bool` だが `spotlightEnabled` は `Configuration.Spotlight`（enum）であり、`config.simulcastEnabled = true` と `config.spotlightEnabled = .enabled` が混在する。`spotlightEnabled` を `Bool` で設定できる新プロパティを追加し、既存の enum プロパティを非推奨化することで、API の一貫性を高める。

## 優先度根拠

Low とする。機能上の不具合ではなく API の使い勝手・一貫性に関する改善であり、緊急性は低い。既存利用者への影響を考慮し、破壊的変更を避けて段階的な非推奨化が前提となるため Low とする。

## 現状

`Configuration.Spotlight`（enum）は `enabled` / `disabled` の 2 値のみで、実質的に真偽値である。

```swift
/// スポットライトの設定
public enum Spotlight {
  /// 有効
  case enabled

  /// 無効
  case disabled
}
```

`Sora/Configuration.swift:61`

`spotlightEnabled` は `Spotlight` 型で定義されており、`simulcastEnabled` 等の `Bool` プロパティと型が不揃いになっている。

```swift
/// スポットライトの可否
/// 詳しくは Sora のスポットライト機能を参照してください。
public var spotlightEnabled: Spotlight = .disabled
```

`Sora/Configuration.swift:182`

`SignalingConnect.spotlightEnabled` も `Configuration.Spotlight` 型（`Sora/Signaling.swift:314`）で、エンコード時に `switch spotlightEnabled` で分岐している。

```swift
switch spotlightEnabled {
case .enabled:
  try container.encode(true, forKey: .spotlight)
  try container.encodeIfPresent(spotlightNumber, forKey: .spotlight_number)
  if spotlightFocusRid != .unspecified {
    try container.encode(spotlightFocusRid, forKey: .spotlight_focus_rid)
  }
  if spotlightUnfocusRid != .unspecified {
    try container.encode(spotlightUnfocusRid, forKey: .spotlight_unfocus_rid)
  }
case .disabled:
  break
}
```

`Sora/Signaling.swift:1011`

`PeerChannel` は `spotlightEnabled: configuration.spotlightEnabled`（`Sora/PeerChannel.swift:397`）をそのまま渡している。

## 設計方針

1. 破壊的変更を避けるため、既存の `spotlightEnabled: Spotlight`（enum）は残したまま `@available(*, deprecated, ...)` で非推奨化する。
2. 同等の機能を持つ `Bool` 型のプロパティを新設する。命名は既存の `Bool` プロパティ（`simulcastEnabled` 等）との整合を取って決定する。
3. 旧 enum プロパティと新 Bool プロパティは内部的に同じ状態を指すよう相互変換する（一方を真値の保管先とし、もう一方を計算プロパティにする）。どちらを設定しても最終的に `SignalingConnect` へ正しく反映されるようにする。
4. `SignalingConnect` 側のエンコードは最終的に真偽値で判定できるよう整理する。ただし既存の enum 受け渡しを壊さない。
5. 後方互換性: 既存コードが enum を使い続けても従来どおり動作し、コンパイルエラーにならない（非推奨警告のみ）こと。

## 完了条件

- `spotlightEnabled` を `Bool` で設定できる新プロパティが追加されていること。
- 既存の enum 型 `spotlightEnabled` が非推奨化されつつ従来どおり動作すること。
- enum / Bool いずれで設定しても connect メッセージの `spotlight` 出力が等価になること。
- 新旧プロパティの相互整合と connect 出力の等価性を検証するテストを追加すること。
- `CHANGES.md` の `develop` セクションに以下を追記すること:
  ```
  - [ADD] spotlightEnabled を Bool で設定できるプロパティを追加する
    - @担当者
  - [UPDATE] enum 型の Configuration.spotlightEnabled を非推奨にする
    - @担当者
  ```

## 解決方法
