# ICEServerInfo の userName プロパティを username に変更する

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/refactor-iceserverinfo-username

## 目的

`ICEServerInfo` のユーザー名プロパティ名が `userName` になっているが、Sora が返す ICE サーバー情報のキー名、WebRTC の `RTCIceServer`、JSON 上のキーはいずれも `username` である。命名を実データに合わせて `username` に統一し、内部処理も `username` を使うようにする。`userName` は公開 API のため、後方互換性を保ったまま移行する。

## 優先度根拠

- 命名の統一を目的とした純粋なリファクタリングであるため Low とする。
- 機能やユーザー影響のある不具合は無い。

## 現状

`ICEServerInfo` でユーザー名プロパティが `userName` として宣言されている。`userName` は `public` のため外部から参照されている可能性がある。

```swift
// Sora/ICEServerInfo.swift:14
/// ユーザー名
public var userName: String?
```

ネイティブ値生成では WebRTC 側のキー `username` へ渡している。

```swift
// Sora/ICEServerInfo.swift:25
RTCIceServer(
  urlStrings: urls,
  username: userName,
  credential: credential,
  tlsCertPolicy: tlsSecurityPolicy.nativeValue)
```

公開イニシャライザの引数名も `userName` である。

```swift
// Sora/ICEServerInfo.swift:35
public init(
  urls: [String],
  userName: String?,
  credential: String?,
  tlsSecurityPolicy: TLSSecurityPolicy
)
```

`Codable` の `CodingKeys` では JSON キー `username` にマッピングしている。

```swift
// Sora/ICEServerInfo.swift:70
case userName = "username"
```

JSON 上のキーやネイティブ側はすでに `username` だが、Swift プロパティ名・イニシャライザ引数名のみ `userName` になっており、名称が不一致である。

## 設計方針

- 新しい公開プロパティ `public var username: String?` を真の格納プロパティとして追加し、内部処理（`nativeValue`、`Codable`）はすべて `username` を参照するように変更する。
- `userName` は削除せず、`username` への委譲（computed property）として残し、`@available(*, deprecated, message: "Use username instead.")` を付与する。`get { username }` / `set { username = newValue }` とする。
- 公開イニシャライザを `username:` 引数版に変更し、後方互換用に `@available(*, deprecated)` を付けた `userName:` 引数版を残し、内部で `username:` 版へ委譲する。引数ラベル違いのイニシャライザを両方公開するため、`userName:` 版を deprecated 化して曖昧さを避ける。
- `CodingKeys` のケース名を `case username` に揃える（JSON キーはもともと `username` なので raw value 指定は不要になる）。
- public / private の選択: 既存 `userName` が `public` であり利用者が触れる前提だったため、後方互換性の観点から `username` も `public` で宣言する。
- 後方互換性: `userName` を残すことで既存利用コードはコンパイルが通り続ける。エンコード／デコードの JSON 表現は変更前後で一致する。

## 完了条件

- `public var username: String?` が追加され、内部処理（`nativeValue` / `Codable`）がすべて `username` を参照していること。
- `userName` プロパティが `username` への委譲として残り、deprecated 化されていること。
- `username:` を取る公開イニシャライザが追加され、`userName:` 版は deprecated として後方互換で残っていること。
- `Codable` のエンコード／デコード結果（JSON キー `username`）が変更前後で一致すること。
- 既存のテストがすべて通ること。
- 公開 API への deprecated 追加と内部移行のため、`CHANGES.md` の `## develop` セクションに `[UPDATE]` エントリと担当者行を追記すること。

## 解決方法
