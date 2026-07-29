# spotlightEnabled を Bool で設定できるようにする

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-spotlight-enabled-bool
- Polished: 2026-06-05

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

### 1. 新プロパティの追加

- **名前**: `isSpotlightEnabled: Bool` — Swift の Bool プロパティ命名規則に従い `is` プレフィックスを付与する。既存の `spotlightEnabled` は enum に占有されているため新規名が必要となる。
- **デフォルト値**: `false`
- **保管場所**: `Configuration.swift:182` の enum `spotlightEnabled` の直前に stored property として定義する。

### 2. 新旧プロパティの関係（source of truth）

- **`isSpotlightEnabled`** を stored property（真値の保管先）とする。
- **`spotlightEnabled`**（enum）を computed property に変更し、`isSpotlightEnabled` の値から導出する:
  ```swift
  @available(*, deprecated, message: "`isSpotlightEnabled: Bool` を使用してください")
  public var spotlightEnabled: Spotlight {
    get { isSpotlightEnabled ? .enabled : .disabled }
    set { isSpotlightEnabled = (newValue == .enabled) }
  }
  ```
- `Configuration.Spotlight` enum 自体は非推奨化しない。`SignalingConnect` が引き続き `Spotlight` 型を使用するため。

### 3. 競合解決（両方設定された場合）

最後に設定された値が勝つ。新 Bool プロパティ `isSpotlightEnabled` が stored property であるため、enum 経由での設定も内部では Bool を更新し、同一の状態を指す。

### 4. SignalingConnect と PeerChannel の扱い

- `SignalingConnect.spotlightEnabled` は `Configuration.Spotlight` 型のまま変更しない。
- `PeerChannel.swift:397` の `spotlightEnabled: configuration.spotlightEnabled` も変更不要。`configuration.spotlightEnabled` が computed property として Bool → enum 変換を行うため、既存の受け渡しがそのまま機能する。
- `SignalingConnect` のエンコード処理 (`Signaling.swift:1011`) も変更不要。

### 5. 非推奨化

`multistreamEnabled` の非推奨化（`Configuration.swift:84-91`）を参考に、以下のメッセージで非推奨化する:

```swift
@available(*, deprecated, message: "`isSpotlightEnabled: Bool` で設定してください。2027 年中に廃止予定")
```

### 6. 後方互換性

既存コードが enum を使い続けても従来どおり動作し、コンパイルエラーにならない（非推奨警告のみ）。`SignalingConnect` / `PeerChannel` の内部実装は変更不要のため、SDK 内部にも破壊的変更は発生しない。

## テスト方針

`SoraTests/` に以下のテストケースを追加する:

| # | ケース | 検証内容 |
|---|--------|---------|
| 1 | `isSpotlightEnabled = true`（デフォルト値から設定） | connect JSON に `"spotlight": true` が含まれること |
| 2 | `isSpotlightEnabled = false`（明示的に無効化） | connect JSON に `spotlight` キーが含まれないこと |
| 3 | デフォルト値（`isSpotlightEnabled` 未設定） | connect JSON に `spotlight` キーが含まれないこと |
| 4 | `spotlightEnabled = .enabled`（旧 enum で設定） | connect JSON に `"spotlight": true` が含まれ、`isSpotlightEnabled` が `true` を返すこと |
| 5 | `spotlightEnabled = .disabled`（旧 enum で設定） | connect JSON に `spotlight` キーが含まれず、`isSpotlightEnabled` が `false` を返すこと |
| 6 | Bool → enum → Bool の往復 | 設定値が往復後も変化しないこと |
| 7 | spotlightNumber / spotlightFocusRid / spotlightUnfocusRid との併用 | 新旧どちらのプロパティ経由で spotlight を有効化しても、関連パラメーターが正しくエンコードされること |

## 完了条件

- `isSpotlightEnabled: Bool` が `Configuration` に追加されていること。
- 既存の enum 型 `spotlightEnabled` が computed property に変更され、`@available(*, deprecated)` で非推奨化されていること。
- enum / Bool いずれで設定しても connect メッセージの `spotlight` 出力が等価になること。
- `SignalingConnect` / `PeerChannel` の内部実装が変更不要であること。
- テストが追加されていること。
- `CHANGES.md` の `develop` セクションに以下を追記すること:
  ```
  - [ADD] spotlightEnabled を Bool で設定できる isSpotlightEnabled プロパティを追加する
    - @担当者
  - [UPDATE] enum 型の Configuration.spotlightEnabled を非推奨にする
    - @担当者
  ```

## 解決方法
