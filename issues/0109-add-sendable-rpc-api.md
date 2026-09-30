# Sendable な RPC API を追加する

- Created: 2026-08-27
- Completed:
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
- ジェネリックな `PutSignalingNotifyMetadata` / `PutSignalingNotifyMetadataItem` は、既存型へ conditional conformance を追加できない。Swift は「non-marker protocol への conditional conformance が marker protocol (`Sendable`) の準拠に依存すること」を禁止しており、`extension PutSignalingNotifyMetadata: SendableRPCMethodProtocol where Metadata: Sendable` は `conditional conformance to non-marker protocol ... cannot depend on conformance of 'Metadata' to marker protocol 'Sendable'` で失敗する (Swift 6.3.3 で実測)。このため新 protocol 用に `SendablePutSignalingNotifyMetadata<Metadata: Codable & Sendable>` と `SendablePutSignalingNotifyMetadataItem<Metadata: Decodable & Sendable, Value: Encodable & Sendable>` を追加し、method 名は既存と同じ定数を使う。params 型 `PutSignalingNotifyMetadataParams` / `PutSignalingNotifyMetadataItemParams` には conditional `Sendable` を追加する (`Sendable` への conditional conformance は許可される)。
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
- `Sora/RPC.swift`: `RPCRawResponse` の `Data` 化と checked `Sendable` 化、`SendableRPCResponse` の追加
- `Sora/MediaChannel.swift`: `sendableRPC` の追加、`decodeRPCResponse` / `decodeRPCResult` の `Data` 入力化
- `SoraTests/SendableConformanceTests.swift`: 新しい公開型の `requireSendable`
- `SoraTests/RpcE2ETests.swift` ほか `SoraTests/`: 新 API の成功 / server error / cancellation / exactly-once
- `TestConsumers/Swift6Consumer/Sources/ConsumerCore/MediaChannelRPC.swift`: 新 API の成功 scenario
- `TestConsumers/Swift6Consumer/NegativeChecks/core-legacy-rpc-associated-type-capture.swift`: 負例
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
