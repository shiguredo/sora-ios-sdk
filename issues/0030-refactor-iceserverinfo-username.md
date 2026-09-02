# ICEServerInfo の userName プロパティを username に変更する

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/refactor-iceserverinfo-username
- Polished: 2026-09-02

## 目的

`ICEServerInfo` のユーザー名プロパティ名が `userName` になっているが、Sora が返す ICE サーバー情報のキー名、WebRTC の `RTCIceServer`、JSON 上のキーはいずれも `username` である。命名を実データに合わせて `username` に統一し、内部処理も `username` を使うようにする。`userName` は公開 API のため、後方互換性を保ったまま移行する。

## 優先度根拠

- 命名の統一を目的とした純粋なリファクタリングであるため Low とする。
- 機能やユーザー影響のある不具合は無い。

## 現状

`ICEServerInfo` でユーザー名プロパティが `userName` として宣言されている（`Sora/ICEServerInfo.swift` の `userName` プロパティ）。`userName` は `public` のため外部から参照されている可能性がある。

ネイティブ値生成（`nativeValue(insecure:)`）では WebRTC 側の引数名 `username:` に `userName` を渡している。

公開イニシャライザは 2 つあり、いずれも引数名が `userName` である。1 つは `init(urls:userName:credential:)` で、もう 1 つは tlsSecurityPolicy の非推奨化（2027 年廃止予定）に伴い deprecated となっている `init(urls:userName:credential:tlsSecurityPolicy:)`。

`Codable` の `CodingKeys` では JSON キー `username` にマッピングしている。

```swift
// Sora/ICEServerInfo.swift の `CodingKeys`
case userName = "username"
```

`init(from:)` 内でも `forKey: .userName` でデコードし、内部変数名も `userName`。

JSON 上のキーやネイティブ側はすでに `username` だが、Swift プロパティ名・イニシャライザ引数名のみ `userName` になっており、名称が不一致である。

## 設計方針

- 新しい公開プロパティ `public var username: String?` を真の格納プロパティとして追加し、内部処理（`nativeValue(insecure:)`、`Codable`）はすべて `username` を参照するように変更する。
- `nativeValue(insecure:)` の `RTCIceServer` 生成を `username: username` に変更する。
- `userName` は削除せず、`username` への委譲（computed property）として残し、`@available(*, deprecated, message: "Use username instead.")` を付与する。`get { username }` / `set { username = newValue }` とする。
- 公開イニシャライザは 2 つある。`init(urls:userName:credential:)` は `username:` 引数版 `init(urls:username:credential:)` に変更し、後方互換用に `@available(*, deprecated, message: "Use username instead.")` を付けた `convenience init(urls:userName:credential:)` を残して `username:` 版へ委譲する。
- `init(urls:userName:credential:tlsSecurityPolicy:)` は tlsSecurityPolicy の非推奨化（2027 年廃止予定）に伴う deprecated イニシャライザのため改名の対象外とする。引数名 `userName` のまま維持し、内部では格納プロパティ `username` を設定する。
- `CodingKeys` のケース名を `case username` に揃える（JSON キーはもともと `username` なので raw value 指定は不要になる）。変更後 `init(from:)` と `encode(to:)` 内の `.userName` 参照はすべて `.username` に変更し、ローカル変数名も `username` に統一する。
- 後方互換性: `userName` を残すことで既存利用コードはコンパイルが通り続ける。エンコード／デコードの JSON 表現は変更前後で一致する。

## テスト方針

モック・スタブは使用しない。

- `username` プロパティおよび `init(urls:username:credential:)` が追加されており、`userName` プロパティと `init(urls:userName:credential:)` が deprecated として残っていることをコンパイルで確認する。
- `ICEServerInfo` の JSON エンコード結果のキーが `"username"` であること、および `"username"` キーを持つ JSON がデコードできることを手動確認または既存テストで確認する。
- `userName = "foo"` を設定した場合に `username` も `"foo"` になること（委譲動作）を確認する。
- 既存の全テストがパスすること。

## 完了条件

- `public var username: String?` が追加され、`nativeValue(insecure:)` の `RTCIceServer` 生成が `username: username` を使っていること。
- `CodingKeys` が `case username`（raw value 指定なし）に変更され、`init(from:)` と `encode(to:)` 内の `.userName` 参照がすべて `.username` に変更され、ローカル変数名も `username` に統一されていること。
- `userName` プロパティが `username` への委譲 computed property として残り、`@available(*, deprecated, message: "Use username instead.")` が付与されていること。
- `init(urls:username:credential:)` が追加され、`userName:` 版は `@available(*, deprecated, message: "Use username instead.")` を付けた `convenience init` として `username:` 版へ委譲していること。
- `init(urls:userName:credential:tlsSecurityPolicy:)` が引数名 `userName` のまま維持され、内部で `username` を設定していること。
- `Codable` のエンコード／デコード結果（JSON キー `username`）が変更前後で一致すること。
- 既存のテストがすべて通ること。
- `CHANGES.md` の `## develop` セクションに以下を追記すること:
  ```
  - [UPDATE] ICEServerInfo のユーザー名プロパティを userName から username に変更する
    - @voluntas
  ```

## 解決方法
