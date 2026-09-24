# 廃止予定の MediaChannelConfiguration クラスを削除する

- Created: 2026-09-24
- Completed: {YYYY-MM-DD}
- Branch: feature/remove-media-channel-configuration
- Polished: {YYYY-MM-DD}

## 目的

`@available(*, unavailable)` で既に利用不可にした `MediaChannelConfiguration` クラスと、その定義内だけに残る `// TODO: RTCConfiguration` コメントを削除し、廃止 API の残骸をコードベースから取り除く。

## 現状

- `Sora/MediaChannelConfiguration.swift`（19 行）に `public class MediaChannelConfiguration` が `@available(*, unavailable, message: "このクラスは廃止予定です。廃止後も利用したい場合はこのクラス定義をご自身のソースに組み込んで利用してください。")` 付きで残っている。
- 同ファイル末尾に `// TODO:` と `// TODO: RTCConfiguration` のコメントが残っている。
- クラス本体（`maxBitRate` / `connectionMetadata` / `multistreamEnabled` 等）も全て不要だが、`unavailable` のため削除しても既存利用者にコンパイルエラーは発生しない。
- `Sora/`・`SoraTests/` に本クラスを参照するコードは無い（参照しているのはドキュメントのみ）。

## 設計方針

- `Sora/MediaChannelConfiguration.swift` を削除する。
- リポジトリ内のドキュメントから残存参照を除去する（`skills/sora-ios-sdk/SKILL.md` の非推奨 API 一覧の行）。

## 完了条件

- `Sora/MediaChannelConfiguration.swift` が削除されている。
- `Sora/`・`SoraTests/` に `MediaChannelConfiguration` の参照が無い。
- ビルドが通る。

## 解決方法

- 対象ファイルの削除とドキュメントの参照除去を行う。
