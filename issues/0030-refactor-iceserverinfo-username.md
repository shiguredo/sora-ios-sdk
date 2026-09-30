# ICEServerInfo の userName プロパティを username に変更する

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/refactor-iceserverinfo-username
- Polished: 2026-09-30

## 目的

`ICEServerInfo` のユーザー名プロパティ名が `userName` になっているが、Sora が返す ICE サーバー情報のキー名、WebRTC の `RTCIceServer`、JSON 上のキーはいずれも `username` である。命名を実データに合わせて `username` に統一し、内部処理も `username` を使うようにする。`userName` は公開 API のため、後方互換性を保ったまま移行する。

## 優先度根拠

- 命名の統一を目的とした純粋なリファクタリングであるため Low とする。
- 機能やユーザー影響のある不具合は無い。

## 現状

`ICEServerInfo` でユーザー名プロパティが `userName` として宣言されている（`Sora/ICEServerInfo.swift` の `userName` プロパティ、格納プロパティ）。`userName` は `public` のため外部から参照されている可能性がある。

ネイティブ値生成（`RTCIceServer` の生成）は `Sora/ICEServerInfo.swift` には無く、`Sora/ConnectionConfigurationSnapshot.swift` の `ICEServerSnapshot.nativeValue(insecure:)` が行っている。`ICEServerSnapshot` はすでに `username` プロパティを持ち、`ICEServerInfo.userName` からネイティブ値への橋渡しは `ICEServerSnapshot.init(_ info: ICEServerInfo)` の `username: info.userName` が担っている。

公開イニシャライザは 2 つあり、いずれも引数名が `userName` である。1 つは `init(urls:userName:credential:)` で、もう 1 つは tlsSecurityPolicy の非推奨化（2027 年廃止予定）に伴い deprecated となっている `init(urls:userName:credential:tlsSecurityPolicy:)`。

`Codable` の `CodingKeys` では JSON キー `username` にマッピングしている。

```swift
// Sora/ICEServerInfo.swift の `CodingKeys`
case userName = "username"
```

`init(from:)` 内でも `forKey: .userName` でデコードし、内部変数名も `userName`。

JSON 上のキーやネイティブ側はすでに `username` だが、Swift プロパティ名・イニシャライザ引数名のみ `userName` になっており、名称が不一致である。

## 設計方針

- 新しい公開プロパティ `public var username: String?` を真の格納プロパティとして追加し、`Codable` と `ICEServerSnapshot` への写し取りはすべて `username` を参照するように変更する（`nativeValue(insecure:)` は `ICEServerSnapshot` のメソッドであり、すでに `username` を使っているため変更対象としない）。
- `ICEServerSnapshot.init(_ info: ICEServerInfo)`（`Sora/ConnectionConfigurationSnapshot.swift` の `ICEServerSnapshot`）の `username: info.userName` を `username: info.username` に変更する。`userName` の非推奨化後は SDK 内部から非推奨 API を参照しない。あわせて `ICEServerSnapshot.username` の doc コメント（「`ICEServerInfo` の `userName` は非推奨となり `username` へ移行する予定のため、snapshot 側は `username` とする」）を、移行完了後の記述（`ICEServerInfo.username` から写し取る旨）へ更新する。
- `userName` は削除せず、`username` への委譲（computed property）として残し、`@available(*, deprecated, message: "Use username instead.")` を付与する。`get { username }` / `set { username = newValue }` とする。
- 公開イニシャライザは 2 つある。`init(urls:userName:credential:)` は `username:` 引数版 `init(urls:username:credential:)` に変更する（本体では `0138` で導入した真値 `isTLSInsecure = false` の設定を維持する）。後方互換用に `@available(*, deprecated, message: "Use username instead.")` を付けた `convenience init(urls:userName:credential:)` を残して `username:` 版へ委譲する。
- `init(urls:userName:credential:tlsSecurityPolicy:)` は tlsSecurityPolicy の非推奨化（2027 年廃止予定）に伴う deprecated イニシャライザのため改名の対象外とする。引数名 `userName` のまま維持し、内部では格納プロパティ `username` と、`0138` の `isTLSInsecure = (tlsSecurityPolicy == .insecure)` を設定する。
- `CodingKeys` のケース名を `case username` に揃える（JSON キーはもともと `username` なので raw value 指定は不要になる）。変更後 `init(from:)` と `encode(to:)` 内の `.userName` 参照はすべて `.username` に変更し、ローカル変数名も `username` に統一する。
- 後方互換性: `userName` を残すことで既存利用コードはコンパイルが通り続ける。エンコード／デコードの JSON 表現は変更前後で一致する。
- 公開 API の変更（`username` プロパティと `init(urls:username:credential:)` の追加、`userName` の stored → computed 変更と非推奨化）を反映するため、`TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json` を同じ変更で `make api-baseline` により再生成し、`CODEBASE.md` の手順に従って差分をレビューする（`make api-check-fresh` が CI の gate である）。
- 非推奨 API の後方互換を外部 consumer 側でも固定する。`TestConsumers/Swift6Consumer/Sources/ConsumerLegacy/DeprecatedAPI.swift` に `userName` プロパティと `init(urls:userName:credential:)` の参照を追加し、`.github/workflows/consumer-test.yml` の `Check Deprecation Warning` が検査する symbol 一覧に `'userName'` と `'init(urls:userName:credential:)'` を追加する（同 step のコメントが、`DeprecatedAPI.swift` の参照を増減する作業は一覧も同時に更新することを定めている）。

## テスト方針

モック・スタブは使用しない。

- `username` プロパティおよび `init(urls:username:credential:)` が追加されており、`userName` プロパティと `init(urls:userName:credential:)` が deprecated として残っていることをコンパイルで確認する。
- 既存の `SoraTests/ConnectionConfigurationSnapshotTests.swift` のうち、非推奨 API の検証を意図しないフィクスチャ（`testICEServerSnapshotCopiesPolicyFromICEServerInfo` と `testICEServerInfoDelegatesTLSecurityPolicyToInternalValue` の `ICEServerInfo(urls:userName:credential:)`）は `init(urls:username:credential:)` へ書き換える（テストが観測する値は変えない）。後方互換を検証するための意図的な非推奨 API の参照だけを残す（`SoraTests` の gate は非推奨警告を warning のまま残す契約である）。
- `ICEServerInfo` の JSON エンコード結果のキーが `"username"` であること、および `"username"` キーを持つ JSON がデコードできることを手動確認または既存テスト（`SoraTests/ConnectionConfigurationSnapshotTests.swift` の `testICEServerInfoJSONKeysAreUnchanged`）で確認する。
- `userName = "foo"` を設定した場合に `username` も `"foo"` になること（委譲動作）を確認する。
- 既存の全テストがパスすること。
- `make consumer-build SCHEME=ConsumerLegacy` が成功し、deprecation warning だけが出て、`'userName'` と `'init(urls:userName:credential:)'` の warning が `Check Deprecation Warning` で検出されること。
- `make api-check-fresh` が成功すること。

## 完了条件

- `public var username: String?` が真の格納プロパティとして追加され、`ICEServerSnapshot.init(_ info: ICEServerInfo)`（`Sora/ConnectionConfigurationSnapshot.swift` の `ICEServerSnapshot`）が `username: info.username` で写し取っていること。`git grep -n 'userName' -- Sora/` のヒットが `Sora/ICEServerInfo.swift` の非推奨宣言と非推奨イニシャライザの引数名・本体に限られること（`Sora/ConnectionConfigurationSnapshot.swift` に `userName` が残らず、SDK 内部に非推奨 API の参照を残さない）。
- `CodingKeys` が `case username`（raw value 指定なし）に変更され、`init(from:)` と `encode(to:)` 内の `.userName` 参照がすべて `.username` に変更され、ローカル変数名も `username` に統一されていること。
- `userName` プロパティが `username` への委譲 computed property として残り、`@available(*, deprecated, message: "Use username instead.")` が付与されていること。
- `init(urls:username:credential:)` が追加され、本体で `0138` の真値 `isTLSInsecure = false` を設定し、`userName:` 版は `@available(*, deprecated, message: "Use username instead.")` を付けた `convenience init` として `username:` 版へ委譲していること。
- `init(urls:userName:credential:tlsSecurityPolicy:)` が引数名 `userName` のまま維持され、内部で `username` と `isTLSInsecure = (tlsSecurityPolicy == .insecure)` を設定していること。
- `Codable` のエンコード／デコード結果（JSON キー `username`）が変更前後で一致すること。
- 既存のテストがすべて通ること（`SoraTests/ConnectionConfigurationSnapshotTests.swift` のフィクスチャは `init(urls:username:credential:)` へ移行し、テストが観測する値が変わっていないこと）。
- `TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json` が同じ変更で再生成され、差分が意図した変更（`username` プロパティと `init(urls:username:credential:)` の追加、`userName` の stored → computed 変更と非推奨 annotation）だけであること。`make api-check-fresh` が成功すること。
- `TestConsumers/Swift6Consumer/Sources/ConsumerLegacy/DeprecatedAPI.swift` に `userName` プロパティと `init(urls:userName:credential:)` の参照が追加され、`.github/workflows/consumer-test.yml` の `Check Deprecation Warning` の symbol 一覧に `'userName'` と `'init(urls:userName:credential:)'` が追加され、`make consumer-build SCHEME=ConsumerLegacy` が成功している（deprecation warning のみ）こと。
- `CHANGES.md` の `## develop` の主リスト（`### misc` ではない）に以下を追記すること（種別順に従って既存の `[UPDATE]` の末尾・最初の `[FIX]` の前に置く。公開 API baseline を再生成する SDK 本体の実装変更のため、`### misc` ではなく主リストに置く）:
  ```
  - [UPDATE] ICEServerInfo のユーザー名プロパティを userName から username に変更する
    - @voluntas
  ```

## 解決方法
