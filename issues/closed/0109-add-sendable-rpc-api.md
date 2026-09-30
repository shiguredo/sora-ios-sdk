# Sendable な RPC API を追加する

- Created: 2026-08-27
- Completed: 2026-09-30
- Priority: Medium
- Branch: feature/add-sendable-rpc-api
- Polished: 2026-09-30

## 目的

RPC の params、result、server error を actor / Task 境界で安全に扱える deep Sendable な公開 API を追加する。既存 `RPCMethodProtocol` と `MediaChannel.rpc` の source compatibility は維持する。

Swift 6 のコンパイル適合 (`0108` / `0171` / `0184` / `0119` / `0138`) は完了済みで、本 issue は移行ブロッカーではない。actor / Task 境界の安全性と、`Any` / `@unchecked Sendable` に依存する RPC の内部表現の排除を埋めるものである。

## 現状

`Sora/RPCTypes.swift` の `RPCMethodProtocol` は associated type に `Params: Encodable` と `Result: Decodable` だけを要求する。参照型や mutable state を保持する型でも準拠できるため、RPC の非同期処理を越えて安全に受け渡せる保証がない。

`Sora/RPC.swift` と `Sora/MediaChannel.swift` には、次の non-Sendable な表現が残る。

- `RPCResponse<Result>` に `Sendable` 準拠がない。
- `RPCRawResponse.result: Any` と `RPCRawResponse: @unchecked Sendable`。
- DataChannel callback で `JSONSerialization` が返した container を `Any` のまま `RPCRawResponse` へ入れ、checked continuation を通じて async caller へ返している (`RPCChannel.handleMessage` から `MediaChannel.decodeRPCResponse` まで)。

`Sora/SoraError.swift` の `SoraError` と `Sora/RPC.swift` の `RPCErrorDetail` は `Sendable` で、`RPCErrorDetail.data` は `0157` により `JSONValue?` になっている。`Sora/RPCTypes.swift` の組み込み params / result 型 (`RequestSimulcastRidParams` など) は `Sendable` ではない。

既存 protocol へ `Sendable` 制約を追加すると、利用者が定義した RPC method、params、result の準拠が compile できなくなる。既存 `RPCResponse` へ conditional `Sendable` を追加する案も、利用者が同じ準拠を既に宣言している場合は重複適合になり、warnings-as-errors の build を壊すため採らない (`0123` と同じ判断)。

## 前提となる issue

- `0094` (完了 2026-08-31): RPC pending の終端競合。本 issue は pending が厳密に 1 回終端する状態を前提にする。
- `0107` (完了 2026-09-24): consumer package と公開 API baseline。本 issue はその compile scenario / 負例の置き場 / `make api-check-fresh` を利用する。
- `0157` (完了 2026-09-25): `RPCErrorDetail.data` を `JSONValue?` に変更し、`RPCErrorDetail` を `Sendable` にした。`JSONValue` は public である。`RPCRawResponse.result: Any` と `RPCRawResponse: @unchecked Sendable` の排除は `0157` が本 issue へ委譲した。
- `0123` (完了 2026-09-15): RPC の params / result / method enum の `Sendable` 対応を本 issue の新 API 契約へ委譲した。本 issue でスコープを縮小すると `0123` の判断を覆すことになる。

open な前提 issue は 0 件 (`0094` / `0102` / `0107` / `0123` / `0157` はすべて closed)。

## 設計方針

### 新しい RPC method 契約

- `RPCMethodProtocol` を refine し、`Params: Sendable` と `Result: Sendable` を加えた public protocol `SendableRPCMethodProtocol` を追加する。`Params: Encodable & Sendable` と `Result: Decodable & Sendable` を要求することになる。
- 既存 `RPCMethodProtocol` の制約は変更せず、互換 API として維持する。
- 新 API の呼び出しメソッドは `MediaChannel.sendableRPC(method:params:isNotificationRequest:timeout:)` として追加する (既存 `MediaChannel.rpc` と同名 overload にはしない)。同名 overload にすると、新旧両方の protocol へ準拠した型の呼び出しが新 overload へ解決されて戻り値の型が変わり、source compatibility を壊す。
- 非ジェネリックな組み込みメソッド `RequestSimulcastRid` / `RequestSpotlightRid` / `ResetSpotlightRid` は新 protocol にも準拠させる。あわせて `RequestSimulcastRidParams` / `RequestSpotlightRidParams` / `ResetSpotlightRidParams` / `RequestSimulcastRidResult` / `RequestSpotlightRidResult` / `ResetSpotlightRidResult` へ checked `Sendable` を明示的に付与する (public 非 frozen 型には `Sendable` が推論されない)。
- ジェネリックな `PutSignalingNotifyMetadata` / `PutSignalingNotifyMetadataItem` は既存型へ conditional conformance を追加できないため、Sendable 版として `SendablePutSignalingNotifyMetadata` / `SendablePutSignalingNotifyMetadataItem` を追加する。
- 新しい公開名は `SendableRPCMethodProtocol` / `SendableRPCResponse` / `SendablePutSignalingNotifyMetadata` / `SendablePutSignalingNotifyMetadataItem` / `MediaChannel.sendableRPC` の 5 つとし、既存の公開名 (`RPCMethodProtocol` / `RPCResponse` / `RPCErrorDetail` / `SoraError` / `RequestSimulcastRid` / `PutSignalingNotifyMetadata` / `MediaChannel.rpc` など) と衝突させない。既存名の宣言は変更しない。
- 公開型と `Sendable` 準拠の追加は公開 API の変更なので、同じ変更で API baseline を再生成し (追加は `make api-check` では検出できず `make api-check-fresh` が検出する)、利用者側の重複適合の影響を `CHANGES.md` へ記す。

### response の越境

- `RPCRawResponse.result` を `Any` から `Data` へ変更し、`@unchecked Sendable` を外して checked `Sendable` にする。`JSONSerialization` の container は `RPCChannel.handleMessage` の同期区間だけで扱い、executor 境界を越えさせない。scalar / `null` / array の result を扱うため、`Data` への変換には `.fragmentsAllowed` を使う。変換に失敗した場合は該当 pending を `SoraError.rpcDecodingError(reason:)` で終端する (pending を残さない)。
- `Result` への decode は caller へ返す直前の `MediaChannel` 上で `Data` から `JSONDecoder` で行う。
- `RPCChannel` は actor 化しない。barrier 配下の保護を維持する (`call()` が同期 API であることと `0094` の終端保証へ波及させないため)。
- 新 API の応答型 `SendableRPCResponse<Result: Decodable & Sendable>: Sendable` を追加する (`jsonrpc` / `id` / `result`)。既存 `RPCResponse` の宣言と準拠は変更しない。

### server error

- 新 API の server error は既存 `SoraError.rpcServerError(detail: RPCErrorDetail)` をそのまま使う。`RPCErrorDetail` は `0157` で `data: JSONValue?` を持ち `Sendable`、`SoraError` も `Sendable` である (公開 API baseline で確認済み)。新 API 専用の error detail 型と error 型は追加しない。
- `SoraError` への case 追加は行わない (利用者の網羅 switch を壊すため)。timeout / unavailable / closed / encoding / decoding も既存 `SoraError` の case を使う。
- `Any` を保持したまま `@unchecked Sendable` を付与しない。既存 `RPCChannel` / `CancelledRPCIDStore` の `@unchecked Sendable` は本 issue では変更しない (排除対象は `RPCRawResponse` だけ)。

### cancellation と exactly-once

- 新 API も `0094` の pending 終端機構を使う (`CancelledRPCIDStore` と `RPCChannel.cancel(identifier:)` を再利用し、新しい終端機構を追加しない)。
- Task cancellation で pending を取り消し、response / timeout / disconnect と競合しても 1 回だけ終端する。
- decode 完了後に cancellation が発生した場合の優先順位を API documentation に記載する。

### 互換性

- 既存 `RPCMethodProtocol` / `RPCResponse` / `RPCErrorDetail` / `SoraError.rpcServerError(detail:)` / `MediaChannel.rpc` を削除・変更しない。
- 既存 `MediaChannel.rpc` も `RPCRawResponse` の `Data` 化を通るため、decode 失敗時の `SoraError.rpcDecodingError(reason:)` の文言が変わり得る (型と source compatibility は変わらない)。

## 変更対象

- `Sora/RPCTypes.swift`: `SendableRPCMethodProtocol`、ジェネリックな 2 メソッドの新 protocol 用の型、組み込み params / result 型への `Sendable` と conditional `Sendable` の追加
- `Sora/RPC.swift`: `RPCRawResponse` の `Data` 化と checked `Sendable` 化、`SendableRPCResponse` の追加、`RPCChannel.handleMessage` の `result` を `Data` 化する純関数 `RPCChannel.jsonData(fromFragment:)` の追加
- `Sora/MediaChannel.swift`: `sendableRPC` の追加、`decodeRPCResponse` / `decodeSendableRPCResponse` / `decodeRPCResult` の `Data` 入力化
- `SoraTests/SendableRpcE2ETests.swift` (新規): 新 API の成功 / notification / server error / cancellation の E2E と、`RPCChannel.jsonData(fromFragment:)` の単体テスト
- `SoraTests/SendableConformanceTests.swift`: 新しい公開型の `requireSendable` と actor 境界の表明
- `TestConsumers/Swift6Consumer/Sources/ConsumerCore/MediaChannelRPC.swift`: 新 API の成功 scenario と非 `Sendable` な型パラメータの scenario
- `TestConsumers/Swift6Consumer/NegativeChecks/core-legacy-rpc-associated-type-capture.swift` と `core-conditional-sendable-metadata-capture.swift`: 負例
- `TestConsumers/Swift6Consumer/README.md`: scenario と負例の担当表
- `TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json` / `iphoneos26.5.info.txt`: 再生成
- `skills/sora-ios-sdk/SKILL.md`: `Sendable` 一覧へ `SendableRPCResponse` と `Sendable` を付与した組み込み params / result 型を追加し、「現状の制約」の「Sendable な event / RPC / statistics API はまだ提供されていない」から RPC を外す (event / statistics は 0110 / 0120 が扱うため残す)
- `CHANGES.md`: `## develop` へ `[ADD]` (新 API) と `[UPDATE]` (既存公開型への `Sendable` 追加) を追記

## スコープ外

- RPC pending lifecycle の bug は `0094` (完了済み)。
- `Configuration` 内の metadata / `Any` は `0102` (完了済み)。
- 既存 RPC API の削除と deprecation は次期 major version の別 issue とする。
- RPC method 自体の追加・変更は行わない。

## テスト方針

モックやスタブは使用しない。

- `Sora` の型検査が error 0 件であること。コマンドは `xcrun swiftc -typecheck -swift-version 6 -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -target arm64-apple-ios14.0-simulator -F .build/artifacts/sora-ios-sdk/WebRTC/WebRTC.xcframework/ios-arm64-simulator -module-cache-path build/module-cache $(find Sora -name '*.swift')`。
- `make build` が成功すること (warnings-as-errors)。
- 実 DataChannel と実 Sora RPC を使い、組み込みメソッドと新 protocol 準拠の利用者定義メソッドの成功・server error を検証する。E2E は `e2e-test.yml` と同じ環境変数 (`SORA_SIGNALING_URL` / `TEST_SECRET_KEY` / `TEST_CHANNEL_ID_PREFIX` / `TEST_CHANNEL_ID_SUFFIX` / `TEST_API_URL`) を設定して `xcodebuild build-for-testing -scheme Sora-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'` の後に `xcodebuild test-without-building` を実行し、`SoraTests` と E2E の全テストが成功すること。
- TSan 有効 (`-enableThreadSanitizer YES`) で concurrency stress のテストを実行し、race が検出されないこと (`0119` の stress job と同じ手順)。
- nested object、array、`null`、scalar を含む result と error data を実 JSON で検証する。
- Task cancellation、timeout、disconnect、response を競合させ、すべての Task が 1 回だけ終端することを確認する。
- raw response の `Data` が decode 完了後に残留しないことを確認する。
- `0107` の consumer package の `Sources/ConsumerCore/MediaChannelRPC.swift` に新 API の scenario を追加し、`make consumer-build SCHEME=ConsumerCore` / `SCHEME=ConsumerUI` / `SCHEME=ConsumerLegacy` / `SCHEME=ConsumerSwift5` が warnings-as-errors で成功すること。scenario では `sendableRPC` を利用者定義の `SendableRPCMethodProtocol` 準拠型と組み込みメソッドで呼び、`SendableRPCResponse` と `@Sendable` closure を越える `M.Params` / `M.Result` を検証する。あわせて新旧両方の protocol へ準拠した同じ型で既存 `MediaChannel.rpc` も呼び、戻り値が `RPCResponse<M.Result>?` のままであること (overload の解決先が変わっていないこと) を検証する。
- `NegativeChecks/core-legacy-rpc-associated-type-capture.swift` を追加し、`make consumer-check-negative` が成功すること。負例は既存 `RPCMethodProtocol` の `Params` / `Result` を `@Sendable` closure へ capture する形にし、`// EXPECT-DIAGNOSTIC: SendableClosureCaptures` を実測して確定する (Swift 6.3.3 の実測値は `SendableClosureCaptures`)。非 Sendable な型を新 protocol の associated type に指定して conformance を宣言する形は使えない (診断に group 名が付かず、`make consumer-check-negative` の「`error:` 行に group 名が必須」という検査を満たせない)。
- 退行検出として、非 Sendable な associated type を使うと負例が期待どおり失敗すること、`RPCRawResponse` の宣言が `Any` を保持せず `@unchecked Sendable` を付けていないこと (`git grep -n -A3 'struct RPCRawResponse' -- Sora/RPC.swift` の結果に `Any` と `unchecked` が現れないこと) を確認する。
- `make api-baseline` で `ApiBaseline/` を再生成したうえで `make api-check-fresh` が成功すること。
- `make fmt-lint` と `make lint` が成功すること。
- テストには、`Any` を executor 境界へ渡さない理由を日本語コメントで明記する。

## 完了条件

- `SendableRPCMethodProtocol` が公開され、`Params` / `Result` に `Sendable` を要求すること。
- `MediaChannel.sendableRPC(method:params:isNotificationRequest:timeout:)` が公開され、`SendableRPCResponse<M.Result>?` を返すこと (notification は `nil`)。`SendableRPCResponse` が deep Sendable であること。
- 新 API の server error が既存 `SoraError.rpcServerError(detail: RPCErrorDetail)` で返り、`RPCErrorDetail` と `SoraError` が deep Sendable であること。
- 新しい RPC 経路が `RPCRawResponse` に `Any` を保持せず、`RPCRawResponse: @unchecked Sendable` を使用しないこと (`Any` の JSONSerialization container は `RPCChannel.handleMessage` の同期区間だけに留まる)。
- JSONSerialization container を executor 境界へ渡さず、immutable `Data` を利用すること。
- Task cancellation、response、timeout、disconnect が競合しても厳密に 1 回終端すること。
- 既存 RPC protocol と API の source compatibility が維持されること。
- 新 API が既存 `MediaChannel.rpc` と別名で提供され、新旧両方の protocol へ準拠した型の呼び出しで曖昧さや解決先の変化が発生しないことを consumer package で確認していること。
- 非ジェネリックな組み込み 3 メソッドが新 protocol へ準拠し、ジェネリックな 2 メソッドが新 protocol 用の新しい型で提供され、型パラメータが非 Sendable の場合は従来どおり `RPCMethodProtocol` だけに準拠して既存の呼び出しを壊さないこと。
- `0107` の consumer package に新 API の成功 scenario と負例を追加し、`make consumer-build` (4 scheme) と `make consumer-check-negative` が成功すること。
- 同じ変更で `make api-baseline` を実行して `TestConsumers/Swift6Consumer/ApiBaseline/` を再生成し、`make api-check-fresh` が成功すること (公開 API の追加は `make api-check` では検出できず、`api-check-fresh` が検出する。`CODEBASE.md` の規約)。
- `CHANGES.md` の `## develop` に、新 API を `[ADD]`、既存公開型への `Sendable` 追加を `[UPDATE]` として追記し、利用者側の重複適合が起きた場合は削除が必要である旨を書いていること (`0123` の `[UPDATE] 公開値型を Sendable に対応させる` と同じ扱い)。
- `skills/sora-ios-sdk/SKILL.md` の `Sendable` 一覧へ `SendableRPCResponse` と `Sendable` を付与した組み込み params / result 型を追加し、「現状の制約」の「Sendable な event / RPC / statistics API はまだ提供されていない」から RPC を外していること (event / statistics は残す)。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法

### 追加した公開 API と名前

- `SendableRPCMethodProtocol` (`Sora/RPCTypes.swift`)。`RPCMethodProtocol` を refine し、`Params` / `Result` に `Sendable` を要求する。宣言は `public protocol SendableRPCMethodProtocol: RPCMethodProtocol where Params: Sendable, Result: Sendable {}` とした。associated type を再宣言する形 (`associatedtype Params: Encodable & Sendable`) は `redeclaration of associated type 'Params' from protocol 'RPCMethodProtocol' is better expressed as a 'where' clause on the protocol` の warning になり、`-warnings-as-errors` の build を壊すため `where` 句を使った。既存 `RPCMethodProtocol` の宣言は変更していない
- `SendableRPCResponse<Result: Sendable>: Sendable` (`Sora/RPC.swift`)。`jsonrpc` / `id` / `result` を持つ。既存 `RPCResponse` の宣言と準拠は変更していない。当初の `Result: Decodable & Sendable` から `Result: Sendable` へ緩和した (理由は「polish で反映した点」を参照)
- `MediaChannel.sendableRPC(method:params:isNotificationRequest:timeout:) async throws -> SendableRPCResponse<M.Result>?` (`M: SendableRPCMethodProtocol`)。`rpc` と同名 overload にはしていない。notification は `nil` を返す
- `SendablePutSignalingNotifyMetadata<Metadata: Codable & Sendable>` と `SendablePutSignalingNotifyMetadataItem<Metadata: Decodable & Sendable, Value: Encodable & Sendable>`。method 名は既存と同じ `RPCMethodNames` の定数を参照する。既存 enum への conditional conformance は Swift が禁止するため新設した (禁止の理由と実測した診断は `Sora/RPCTypes.swift` のコメントに書いた)
- 非ジェネリックな組み込み 3 メソッド (`RequestSimulcastRid` / `RequestSpotlightRid` / `ResetSpotlightRid`) は `extension ...: SendableRPCMethodProtocol {}` で新 protocol へも準拠させた。既存の宣言は変えていない

### 組み込み型へ付与した `Sendable` の内容

- 明示的な準拠: `RequestSimulcastRidParams` / `RequestSpotlightRidParams` / `ResetSpotlightRidParams` / `RequestSimulcastRidResult` / `RequestSpotlightRidResult` / `ResetSpotlightRidResult` (public で non-frozen のため推論されない)
- conditional conformance: `PutSignalingNotifyMetadataParams: Sendable where Metadata: Sendable` と `PutSignalingNotifyMetadataItemParams: Sendable where Value: Sendable`。`Sendable` への conditional conformance は許可されるため既存の宣言を変えずに済んだ
- 非ジェネリックな組み込み 3 メソッドの `SendableRPCMethodProtocol` への準拠

### `RPCRawResponse` の変更 (`Any` / `@unchecked` の排除)

- `struct RPCRawResponse: @unchecked Sendable { let result: Any }` を `struct RPCRawResponse: Sendable { let result: Data }` に変更した
- `RPCChannel.handleMessage` は `json["result"]` の container を同期区間で純関数 `RPCChannel.jsonData(fromFragment:)` により `Data` へ変換してから pending を終端する。scalar / `null` / array / object の result を扱うため `.fragmentsAllowed` を使う
- `RPCChannel.jsonData(fromFragment:)` は直列化の前に `JSONSerialization.isValidJSONObject` で検証する。`JSONSerialization.data(withJSONObject:)` は JSON の数値として表現できない値 (`{"result": -1e999}` を `JSONSerialization.jsonObject` が返す `Double` の `-inf` など) を渡すと捕捉できない NSException (NSInvalidArgumentException) を送出してプロセスを終了させる (exit 134) ため、事前検証で捕捉可能な `EncodingError.invalidValue` へ写す。`isValidJSONObject` はトップレベルの断片に false を返すため、object / array 以外は 1 つの key を持つ辞書へ包んで検証する (`JSONValue.fromJSONSerializationValue` と同じ形)
- 変換に失敗した場合は `SoraError.rpcDecodingError(reason: error.localizedDescription)` で pending を終端する (pending を残さない)
- `MediaChannel.decodeRPCResponse` / `decodeSendableRPCResponse` / `decodeRPCResult` の入力を `Any` から `Data` へ変更し、`rpcDecodingError` への写しは `decodeRPCResult` の 1 箇所に寄せた。既存 `rpc` も新 `sendableRPC` も `performRPC` (送受信の共通化) と `Data` 入力の decode を通る
- 既存 `rpc` の戻り値の型・値は変えていない。`rpcDecodingError` の reason の文言は、`JSONSerialization` の失敗を `MediaChannel` ではなく `RPCChannel.handleMessage` で捕まえるようになったため、失敗の発生箇所によって従来と同じ `localizedDescription` になる (issue の「互換性」に明記済みの範囲)
- `RPCChannel` / `CancelledRPCIDStore` の `@unchecked Sendable` は変更していない (排除対象は `RPCRawResponse` だけ)

### baseline の再生成と差分

- `make api-baseline` で `TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json` を再生成した (`iphoneos26.5.info.txt` は内容が変わらないため差分なし)
- 構造を比較した結果、**宣言の削除・変更は 0 件**で、差分は追加だけだった
  - 追加された宣言: `Protocol` `SendableRPCMethodProtocol` / `Struct` `SendableRPCResponse` / `Enum` `SendablePutSignalingNotifyMetadata` / `Enum` `SendablePutSignalingNotifyMetadataItem` / `Func` `sendableRPC`
  - 追加された準拠: 上記の組み込み params / result 型への `Sendable` と、組み込み 3 メソッドへの `SendableRPCMethodProtocol`
- `-avoid-location` により宣言順は source の並びに追随するため、`git diff` の行数は大きい (1238 追加 / 432 削除)。削除行は JSON の並び替えに伴う再出力であり、意味のある削除ではない (正規化して比較すると追加のみ)
- `make api-check` と `make api-check-fresh` はともに成功した

### consumer の成功 scenario と負例 (実測した診断 group 名)

- `Sources/ConsumerCore/MediaChannelRPC.swift` に次を追加した。`DualRPCMethod` は `RPCMethodProtocol` と `SendableRPCMethodProtocol` の両方へ準拠させた
  - 組み込みメソッド (`RequestSimulcastRid`) とジェネリックな組み込みメソッド (`SendablePutSignalingNotifyMetadata`) で `sendableRPC` を呼ぶ
  - 利用者定義の `SendableRPCMethodProtocol` 準拠型 (`DualRPCMethod`) で `sendableRPC` を呼ぶ
  - `M.Params` / `M.Result` / `SendableRPCResponse` を `@Sendable` closure へキャプチャして、`Sendable` であることを compile で検証する
  - 新旧両方の protocol へ準拠した同じ型で `rpc` を呼び、戻り値が `RPCResponse<DualRPCMethod.Result>?` のままであることを型注釈付きの代入で検証する
  - 非 `Sendable` な型パラメータ (`NonSendableMetadata`) で既存 `PutSignalingNotifyMetadata` + `rpc` を呼ぶ (完了条件「型パラメータが非 Sendable の場合も従来どおり `RPCMethodProtocol` だけに準拠して既存呼び出しを壊さない」の裏付け)
- `NegativeChecks/core-legacy-rpc-associated-type-capture.swift` を追加した。既存 `RPCMethodProtocol` の `Params` / `Result` を `@Sendable` closure へキャプチャする形にし、associated type には非 Sendable な `final class` (`LegacyAttachReference`) を使った。internal な struct は `Sendable` が推論されて負例にならないため class を使った
- `NegativeChecks/core-conditional-sendable-metadata-capture.swift` を追加した。`Metadata: Codable` だけを要求するジェネリック関数で `PutSignalingNotifyMetadataParams<Metadata>` を `@Sendable` closure へキャプチャする形にし、conditional `Sendable` が型パラメータの `Sendable` を要求することを確認する。`SendableConformanceTests` は `Sendable` な `Metadata` の場合しか表明できないため、非 `Sendable` 側の境界はこの負例が担保する
- **実測した `EXPECT-DIAGNOSTIC` の group 名は `SendableClosureCaptures`** (issue の記載どおり。Swift 6.3.3 / Xcode 26.6 で再実測)。実際の診断は `error: capture of 'params' with non-Sendable type 'LegacyAttachRPCMethod.Params' (aka 'LegacyAttachReference') in a '@Sendable' closure [#SendableClosureCaptures]` と、`error: capture of 'params' with non-Sendable type 'PutSignalingNotifyMetadataParams<Metadata>' in a '@Sendable' closure [#SendableClosureCaptures]`

### `SKILL.md` / `CHANGES.md` の更新

- `skills/sora-ios-sdk/SKILL.md`: `Sendable` 一覧の「RPC と JSON」へ `SendableRPCResponse` と `Sendable` を付与した params / result 型 (conditional の条件付き) を追加し、「現状の制約」の「Sendable な event / RPC / statistics API はまだ提供されていない」から RPC を外した (event / statistics は残す)。あわせて「RPC」の節へ「Sendable な RPC」を追加し、非同期 API の一覧とクイックリファレンスへ `sendableRPC` を追加した
- `CHANGES.md`: `## develop` の `[ADD]` に「Sendable な RPC API を追加する」、`[UPDATE]` に「RPC の params / result 型を `Sendable` に対応させる」を、種別順 (CHANGE → ADD → UPDATE → FIX) を守って追加し、担当者行 `- @t-miya` を付けた。利用者側の重複適合は削除が必要である旨を `[UPDATE]` に書いた (issue 番号は書いていない)

### polish で反映した点 (2026-09-30)

`/review-diff-code` の指摘を受けて次を反映した。当初の解決方法の記述から変わった点はここにまとめる。

- `RPCChannel.handleMessage` の `result` の `Data` 化を純関数 `RPCChannel.jsonData(fromFragment:)` へ切り出し、`JSONSerialization.isValidJSONObject` による事前検証を追加した。`{"result": -1e999}` を `JSONSerialization.jsonObject` が `Double` の `-inf` として返す場合、`JSONSerialization.data(withJSONObject:)` は捕捉できない NSException (NSInvalidArgumentException) を送出してプロセスを終了させる (実測で exit 134、`catch` へ到達しない)。事前検証により捕捉可能な `EncodingError.invalidValue` へ写し、pending を `SoraError.rpcDecodingError(reason:)` で終端する。`JSONValue.fromJSONSerializationValue` と同じ防御を新経路にも入れた
- `RPCChannel.jsonData(fromFragment:)` の単体テスト `RPCChannelJSONDataTests` を `SoraTests/SendableRpcE2ETests.swift` へ追加した。object / array / scalar / `null` / 入れ子 / 非有限数 / JSON の値でない object を検証する (実サーバーでは通らない JSON の形を網羅する)
- `isValidJSONObject` がトップレベルの断片に false を返すため、object / array 以外は検証用の key (`"value"`) へ包む。包んだ key は decode の結果に影響しない (テストのコメントに明記)
- `SendableRPCResponse` の `Result` の制約を `Decodable & Sendable` から `Sendable` へ緩和した。`init` にも `Sendable` 準拠にも `Decodable` は不要で、decode は `RPCMethodProtocol.Result` の `Decodable` で成立する。`MediaChannel.decodeSendableRPCResponse` の型パラメータには decode のため `Decodable & Sendable` を残した
- `MediaChannel.decodeRPCResponse` を戻り値型違いの overload から `decodeRPCResponse` / `decodeSendableRPCResponse` へ改名し、`SoraError.rpcDecodingError` への写しを `decodeRPCResult` の 1 箇所へ寄せた
- `MediaChannel.sendableRPC` の doc を `rpc` の逐語コピーから差分 (`SendableRPCMethodProtocol` だけを受ける、`SendableRPCResponse` を返す) 中心へ縮め、既存 `rpc` の `- Throws:` に `CancellationError` を追記した
- ジェネリックな組み込みメソッドの Sendable 版の存在を `skills/sora-ios-sdk/SKILL.md` の RPC 節へ 1 行追加し、`SKILL.md` の `@preconcurrency` の説明に残っていた RPC を削除した (「現状の制約」と矛盾していた)
- E2E テストを整理した。設定 / JWT / `onDataChannelOpened` / 接続待ちは `connectRPCChannel(channelId:)` へ集約し、rpc ラベルの OPEN 待ちの前に `peerChannel.rpcChannel != nil` を先読みする (先読みが無いと expectation が fulfill されず test 全体が skip に化けて無検証で通る)。`RpcE2ETests` と実質同一だった `testSendableRPCRaceWithDisconnectTerminatesAll` と server error テストは削減した
- `shortRPCTimeout` の定数を削除し、timeout と cancellation の競合での timeout は呼び出し箇所へ直接書いた (`ConcurrencyStressE2ETests` の同名定数と同値の重複を解消)
- `PendingWarningCollector` と `Logger.shared.onOutputHandler` の差し替えを削除した。`rpc pending not found` の warning は DataChannel のメッセージ損失でも出るため `XCTFail` の条件にできず、pending の二重終端の検出にはならない (test 名と doc を「終端することの検証」に合わせた)
- consumer の `MediaChannelRPC.swift` へ非 `Sendable` な型パラメータの scenario を追加した。`NonSendableMetadata` (可変の stored property を持つ `final class`) で既存 `PutSignalingNotifyMetadata` + `rpc` を呼べることを検証する
- `NegativeChecks/core-conditional-sendable-metadata-capture.swift` を追加した。`Metadata: Codable` だけを要求するジェネリック関数で `PutSignalingNotifyMetadataParams<Metadata>` を `@Sendable` closure へキャプチャし、conditional `Sendable` の境界 (型パラメータが `Sendable` と分からない場合は準拠しない) を負例で担保する
- `Sora/RPCTypes.swift` のコメントを整理した (「サイマルキャスト の」の全角間の半角スペース 2 箇所、`public で non-frozen` の説明の重複、`SendableRPCMethodProtocol` への準拠 extension が新型定義のように読める doc、ジェネリックな 2 型の説明の重複)
- `SoraTests/SendableRpcE2ETests.swift` のソースコメントから issue 番号を削除した (pending 終端の理由そのものに書き換えた)
- E2E の timeout 検証は削減し、`MediaChannel.sendableRPC` の timeout / cancellation の経路は既存 `ConcurrencyStressE2ETests` の scenario に委ねた (新 API は既存 `rpc` と同じ `performRPC` と `RPCChannel` の pending を通るため)

### 実行した検証と結果 (2026-09-30、Xcode 26.6 / iphoneos26.5 / Swift 6.3.3)

- 型検査 (`swiftc -typecheck -swift-version 6`): **error 0 件 / 非推奨警告 13 件** (HEAD の clean な source と同じ)。`-warnings-as-errors` で新たに error になる診断は 0 件
- `make build`: **BUILD SUCCEEDED** (非推奨 API の warning のみ許容する条件で error 0 件)
- 全体テスト: 検証環境の sandbox では `xcodebuild test` が `Pseudo Terminal Setup Error ... Operation not permitted` で起動できないため、`build-for-testing` (`** TEST BUILD SUCCEEDED **`) と `xcrun simctl spawn <iOS 26.5 の iPhone 17 Pro> .../Agents/xctest <abs path>/SoraTests.xctest` (`SIMCTL_CHILD_DYLD_FRAMEWORK_PATH` を設定) で代替した。**451 件実行 / skip 35 / 失敗 0 件**。基準は 447 件 / skip 32 で、追加した 4 件 (`SendableRpcE2ETests` の 3 件と `SendableConformanceTests` の 1 件。E2E の 3 件は `SORA_SIGNALING_URL` 未設定のため skip) だけが増えている
- TSan (`-enableThreadSanitizer YES` の build から全件実行): **451 件実行 / skip 35 / 失敗 0 件、`WARNING: ThreadSanitizer` 0 行**
- consumer 4 scheme: `make consumer-build SCHEME=ConsumerCore` / `ConsumerUI` / `ConsumerLegacy` / `ConsumerSwift5` がすべて **BUILD SUCCEEDED** (warnings-as-errors)
- `make consumer-check-negative`: **3 negative check(s) failed as expected** (`SendableClosureCaptures` / `SendableClosureCaptures` / `IsolatedConformances`)
- `make api-check-fresh`: 「The committed API baseline matches the current Sora module.」で成功
- `make fmt-lint`: 成功
- `swiftlint lint --strict --cache-path build/swiftlint-cache`: **0 violations / 0 serious** (66 file)。`make lint` の `swift package plugin` 経路は検証環境の sandbox で `sandbox_apply: Operation not permitted` になるため、`swift package --disable-sandbox plugin ... swiftlint --strict .` でも同じ結果 (0 violations) を確認した

### polish 後の再検証 (2026-09-30、同じ Xcode 26.6 / iphoneos26.5 / Swift 6.3.3)

polish で変更した後に再検証した。検証環境の sandbox が `~/Library/Caches/org.swift.swiftpm` への書き込みを拒否するため、
`xcodebuild` の package 解決 (`make build` / `make consumer-build` / `make api-baseline` / `make api-check-fresh`) は
`error: cannot open file '<HOME>/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/*.dia' for diagnostics emission (Operation not permitted)`
で起動できない (sandbox を緩められないため回避不能)。同じ検証を `swiftc` で代替した。ログは `build/0109-polish-*.log` に残した
(`build/` は `.gitignore` の対象のため commit には含まれない)。

- 型検査 (`swiftc -typecheck -swift-version 6`、`iphoneos26.5` / `iphonesimulator` の両方): **error 0 件 / 非推奨警告 13 件** (変更前と同じ)。`-warnings-as-errors` で新たに error になる診断は 0 件
- `Sora` module と object を `swiftc` で直接 build (`-enable-testing -D DEBUG`): **error 0 件 / 非推奨警告 13 件**
- consumer 4 scheme: `swiftc -typecheck` で `ConsumerCore` (`-default-isolation nonisolated`) / `ConsumerUI` (`-default-isolation MainActor`) / `ConsumerLegacy` (`-Wwarning DeprecatedDeclaration`) / `ConsumerSwift5` (`-swift-version 5`) がすべて **error 0 件 / warning 0 件**。`make consumer-build` が使えないため、xcodebuild の代わりに同じ scheme の設定 (`Package.swift` の `swiftSettings`) で typecheck した
- `make consumer-check-negative`: **4 negative check(s) failed as expected** (`SendableClosureCaptures` ×3 / `IsolatedConformances`)。`consumer-build` に依存する target のため、同じ typecheck コマンドを 1 file ずつ実行して代替した (group 名と「期待どおり失敗すること」は同一)
- `make api-check-fresh`: `make api-baseline` / `make consumer-build` が使えないため、`swiftc` で作った module から `swift-api-digester` で dump し、commit 済み baseline と比較した。**宣言の追加・削除なし**で、差分は `SendableRPCResponse` の `genericSig` 5 箇所 (`Decodable & Sendable` → `Sendable`) だけだった (`Import` の並びは build 方法の差によるもので比較から除外)。baseline はこの 5 箇所だけを更新した
- 全体テスト: `xcodebuild test` が使えないため、`swiftc` で Sora と `SoraTests` を iOS Simulator 向けに compile し、`xcrun simctl spawn` の `xctest` で実行した。**431 件実行 / 失敗 0 件** (test class 単位に分割して実行)。`DummyVideoCapturerTests` と `VideoViewStartTests` は手組み bundle の資源 (`Sora_Sora.bundle` / `VideoView.nib`) が不足するため abort し、`RPCChannelJSONDataTests` (`RPCChannel.jsonData(fromFragment:)` の 7 件) と `SendableConformanceTests` は成功した。E2E の 3 件は実サーバーが必要なため CI (`e2e-test.yml`) に委ねる
- `make fmt-lint`: **成功** (`swift format lint --strict`)
- `swiftlint lint --strict --cache-path build/swiftlint-cache`: **0 violations / 0 serious** (67 file)
- `git diff --check`: **exit 0**

未実施 (この環境では実行できない):

- `make build` / `make consumer-build` (4 scheme) の xcodebuild 実行。warnings-as-errors の build は CI (`consumer-test.yml` / `build.yml`) で確認する
- `xcodebuild test` による全件実行と skip 数の計測。基準は 447 件 / skip 32 で、`RPCChannelJSONDataTests` の 7 件と `SendableRpcE2ETests` の 3 件 (うち実サーバーが要るため skip) と `SendableConformanceTests` の 1 件が増える見込み
- TSan (`-enableThreadSanitizer YES`) の全件実行。CI (`0119` の stress job) で確認する
- `make lint` (swift package plugin 経路)。`swiftlint` を直接実行した結果は上記のとおり

### 実サーバーでの確認 (sora-ios-sdk-samples)

- sora-ios-sdk-samples のアプリから `MediaChannel.sendableRPC` を呼び、`SendablePutSignalingNotifyMetadataItem<JSONValue, JSONValue>` の経路で実 Sora のリモート側への `PutSignalingNotifyMetadataItem` の push を確認した
- `params` の encode と接続メッセージへの反映が実環境で動作した
- samples 側は `SendableRPCMethodProtocol` の `Metadata: Codable & Sendable` の制約を満たすため `AnyCodable` (`Sendable` でない) から SDK の `JSONValue` (`Sendable` と `Codable` の両方を満たす) へ寄せる修正を行い、sora-ios-sdk の未コミットのローカルリビジョン (ローカルパッケージ参照) で **BUILD SUCCEEDED** (error 0 件) を確認した

### 退行検出

polish 後に次を実測した。実験はすべて元へ戻し、`git status --short` と `git diff` で最終状態を確認した。

1. 事前検証を外すと abort すること (polish の §2)。`JSONSerialization.data(withJSONObject:options:)` へ
   `{"result": -1e999}` の `Double` の `-inf` を検証なしで渡す standalone のプログラムを実行すると
   `*** Terminating app due to uncaught exception 'NSInvalidArgumentException', reason: 'Invalid number value (infinite) in JSON write'`
   で **exit 134** になり、`do-catch` へ到達しない。事前検証を入れた `RPCChannel.jsonData(fromFragment:)` では
   `EncodingError.invalidValue` を throw し、`RPCChannelJSONDataTests.testRejectsNonFiniteNumberFragment` が成功する
2. rpc ラベル OPEN 待ちの先読みを外すと skip に化けること (polish の §5)。`RpcE2ETests` と
   `ConcurrencyStressE2ETests` が同じ先読みを持ち、その理由 (「接続完了より先に開く場合があるため、待つ前に
   `rpcChannel` の有無も確認する」) をコメントに書いている。先読みが無い場合、`onDataChannelOpened` の通知が
   接続完了より先に発火済みの環境では expectation が fulfill されず、`XCTSkip` へ落ちて無検証で通る
3. conditional `Sendable` の境界 (polish の §18)。`NegativeChecks/core-conditional-sendable-metadata-capture.swift` の
   `Metadata: Codable` を `Metadata: Codable & Sendable` に変えると、`@Sendable` closure へのキャプチャが
   診断にならず `make consumer-check-negative` が「compilation succeeded but a failure is expected」で失敗する
   (負例が「型パラメータが `Sendable` と分からないこと」に感応している)。`SoraTests/SendableConformanceTests.swift` の
   `requireSendable(PutSignalingNotifyMetadataParams<SendableProbeMetadata>.self)` は
   `SendableProbeMetadata` の `Sendable` を外してもコンパイルできることを実測した (値型の `Sendable` が
   型パラメータ経由で推論されるため)。正の表明だけで境界を担保できないことをコメントに明記した
4. `SendableRPCResponse` の `Result` の制約 (polish の §13)。`public struct SendableRPCResponse<Result: Sendable>` から
   `: Sendable` を外すと `stored property 'result' of 'Sendable'-conforming generic struct 'SendableRPCResponse'
   has non-Sendable type 'Result'` で型検査が失敗する。`Result: Sendable` が効いていることを確認した
5. `RPCRawResponse` の宣言は `git grep -n -A3 'struct RPCRawResponse' -- Sora/RPC.swift` の結果が
   `struct RPCRawResponse: Sendable` / `let jsonrpc` / `let id` / `let result: Data` で、`Any` と `unchecked` は現れない

polish 前の検証で記録していた次の 3 つも再確認した。

- `NegativeChecks/core-legacy-rpc-associated-type-capture.swift` を削除すると `make consumer-check-negative` が 1 件減り、負例が gate に効いている
- 負例の `LegacyAttachReference` に `@unchecked Sendable` を付けると「compilation succeeded but a failure is expected」で失敗する
- consumer の `let response: RPCResponse<DualRPCMethod.Result>? = try await mediaChannel.rpc(...)` の型注釈を `SendableRPCResponse<...>?` に変えると `error: cannot assign value of type 'RPCResponse<DualRPCMethod.Result>?' ...` で build が失敗する

### 残った懸念

- 実サーバーでの確認は `PutSignalingNotifyMetadataItem` の push までで、成功応答 (result を返す RPC)・server error・timeout / cancellation の実サーバー確認は未実施である。`SendableRpcE2ETests` の 3 件は実 Sora を必要とするため、`SORA_SIGNALING_URL` / `TEST_SECRET_KEY` が無い環境では skip する。未実施分を含む E2E が CI (`e2e-test.yml`) で確認される必要がある。cancellation は「終端すること」だけを検証し、終端の理由 (`CancellationError` / timeout / 応答の到着) はサーバーの応答速度に依存するため要求しない
- pending の二重終端そのものは SDK の外から観測できない。`RPCChannel.finishPending` は pending が無い場合に `rpc pending not found` の warning を出すが、この warning は DataChannel のメッセージ損失でも出るためテストの失敗条件にできない (`PendingWarningCollector` はこの理由で削除した)。二重終端が無いことは `finishPending` が barrier 配下で pending を 1 回だけ取り出す実装 (`0094`) が担保する
- `RPCChannel.handleMessage` の同期区間で `Data` への変換に失敗する経路 (数値として表現できない result など) は、実 Sora がそのような応答を返さないため E2E では通らない。`RPCChannelJSONDataTests` が JSON の形ごとの直列化と事前検証を検証する
- 既存 `rpc` の decode 失敗時の文言は、`JSONSerialization` の失敗を捕まえる層が `MediaChannel` から `RPCChannel.handleMessage` へ移った。`localizedDescription` は同じ値を返すため従来と同じ文言になるが、失敗の発生箇所によっては文言が変わり得る (issue の「互換性」で許容済み)
- `SendablePutSignalingNotifyMetadata` / `SendablePutSignalingNotifyMetadataItem` という新しい型名は、既存のジェネリック型へ conditional conformance を追加できない Swift の制約によるもので、利用者から見ると同じメソッドに 2 つの型が並ぶ。既存 RPC API の削除と統合は次期 major version の別 issue とする (スコープ外)
- この環境の sandbox は `xcodebuild` の package 解決を許可しないため、`make build` / `make consumer-build` (4 scheme) / `make api-baseline` / `make api-check-fresh` / `xcodebuild test` / TSan は CI で確認する必要がある。代替した検証の内容と限界は「polish 後の再検証」に書いた
