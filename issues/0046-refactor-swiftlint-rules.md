# SwiftLint ルールを見直す

- Priority: Low
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/refactor-swiftlint-rules
- Polished: 2026-06-06

## 目的

SwiftLint のルール設定を強化し、force unwrap や暗黙的アンラップ型（IUO）の使用を開発中に検知できるようにする。直近の PR で CI 時にしか発覚しなかった問題を、ローカルの `swiftlint lint` で事前に検知できる状態にする。

## 優先度根拠

直近の PR #334・#335・#336 で force unwrap / IUO 関連の問題が CI レベルで初めて発覚しており、Lint による早期検知がなければ再発リスクがある。ただし既存コードへの影響修正が伴うため、緊急性は低く Low とする。

## 現状

### `.swiftlint.yml` の状態

`.swiftlint.yml` の `disabled_rules` に以下が含まれている:

- `force_cast`, `force_try`: force casting/try の使用を許可している
- `weak_delegate`: weak delegate チェックを無効化している

さらに `opt_in_rules` の指定がなく、以下の opt-in ルールが有効化されていない:

- `force_unwrapping`: force unwrap（`!`）の使用を検知するルール（デフォルト無効）
- `implicitly_unwrapped_optional`: 暗黙的アンラップ型（`Type!`）の宣言を検知するルール（デフォルト無効）

### 直近の PR で Lint 検知できなかったケース

| PR | コミット | 問題 | 検知すべきルール |
|---|---|---|---|
| #334 | `e73aab3` | `URLSessionWebSocketTask.Message!` 型の IUO 宣言 | `implicitly_unwrapped_optional` |
| #335 | `3b433e4` | `weak var cameraVideoCapturer: ...!` の IUO 宣言 | `implicitly_unwrapped_optional` |
| #336 | `ecd8d1e` | `CameraVideoCapturer.current!.isRunning` の force unwrap | `force_unwrapping` |

## 設計方針

`.swiftlint.yml` に `opt_in_rules` セクションを追加し、以下のルールを有効化する:

1. `force_unwrapping`: 上記 PR #336 相当の force unwrap を検知する
2. `implicitly_unwrapped_optional`: 上記 PR #334・#335 相当の IUO 型宣言を検知する。`@IBOutlet` の IUO は Interface Builder との接続に必須のため、`mode: exclude_iboutlets`（`VideoView.swift` の `@IBOutlet` 2 箇所を自動除外）を `.swiftlint.yml` に設定する

新ルールを有効化すると既存コードでルール違反が発生するため、`swiftlint lint` を実行して違反箇所を洗い出し、合わせて修正する。既存コードの違反は `PeerChannel.swift`（`answer!`・`error!`・`sdp!` 等の force unwrap が 20 箇所以上）、`CameraVideoCapturer.swift`、`MediaChannel.swift`（`_peerChannel!` 等）、`DataChannel.swift` 等に多数存在する。`Optional` 化（`?`）または `guard let` への置き換えが困難な箇所は `// swiftlint:disable:next force_unwrapping` でインライン抑制する（抑制理由のコメントは日本語で添えること）。

PR #337 の `[weak self]` 漏れを検知する標準 SwiftLint ルールは SwiftLint 0.63.x には存在しないため、本 issue のスコープ外とする。必要であれば別 issue でカスタムルールの追加を検討する。

`force_cast`・`force_try`・`weak_delegate` の `disabled_rules` への残留については本 issue のスコープ外とし、別 issue で検討する。

## 完了条件

- `.swiftlint.yml` に `opt_in_rules` セクションが追加され、`force_unwrapping` と `implicitly_unwrapped_optional` が有効化されていること
- `swiftlint lint` を実行してルール違反がゼロであること（または各インライン抑制箇所に理由コメントが付いていること）
- PR #334・#335・#336 相当のコードパターン（IUO 型宣言・force unwrap）を今後コードに追加した際に `swiftlint lint` で検知されること（PR #334〜#336 のコードはすでに修正済みのため現行コードには存在しない）
- `CHANGES.md` の `## develop` セクションの `### misc` に以下を追記すること（`### misc` がない場合は新設すること）

```
- [UPDATE] SwiftLint に force_unwrapping / implicitly_unwrapped_optional ルールを追加する
  - @voluntas
```

## 解決方法
