# `RPCErrorDetail.data` を deep-Sendable な表現に変更する

- Created: 2026-08-27
- Completed:
- Priority: Medium
- Branch: feature/change-rpc-error-detail-data
- Polished: 2026-09-24

## 目的

`SoraError.rpcServerError(detail:)` が運ぶ `RPCErrorDetail.data: Any?` を deep-Sendable な表現へ変更し、`SoraError` に出ている Swift 6 の concurrency 警告を解消する。

採用 toolchain の stdlib は `public protocol Error : Swift.Sendable` を宣言しているため、`Error` に準拠する `SoraError` は暗黙に `Sendable` とみなされる。`SoraError` は `case rpcServerError(detail: RPCErrorDetail)` を持ち、`RPCErrorDetail` は `public let data: Any?` を持つため、この associated value が non-Sendable な payload を運ぶという警告が出る。2026-09-24 に Xcode 26.6 / Swift 6.3.3 で `Sora/` を型検査した実測は次のとおり。

```
Sora/SoraError.swift:64:8: warning: associated value 'rpcServerError(detail:)' of 'Sendable'-conforming enum 'SoraError' contains non-Sendable type 'RPCErrorDetail'
Sora/RPC.swift:4:15: note: consider making struct 'RPCErrorDetail' conform to the 'Sendable' protocol
```

`SoraError` は `throws` で actor 境界を越えるため、この警告は「`Sendable` と宣言されている型が non-Sendable な payload を運ぶ」という実際の欠陥を示している。同じ型検査で `SoraError` の他の associated value (`String` / `Error` / `WebSocketStatusCode` / `Int`) には同種の警告が出ておらず、`Sendable` を妨げているのは `RPCErrorDetail.data` だけである。

## 現状

`Sora/RPC.swift` の `RPCChannel.handleMessage` は DataChannel で受け取った JSON を `JSONSerialization` で読み、`error["data"]` をそのまま `RPCErrorDetail.data` へ入れている。

```swift
let detail = RPCErrorDetail(code: code, message: message, data: error["data"])
finishPending(id: identifier, result: .failure(SoraError.rpcServerError(detail: detail)))
```

`RPCErrorDetail` は `code: Int` / `message: String` / `data: Any?` を持ち、`Any?` だけが `Sendable` を妨げている。memberwise イニシャライザは internal なので `@testable import Sora` のテストからは値を組み立てられるが、利用者は `RPCErrorDetail` を組み立てられず `Error` から受け取って読むだけである。

`Sora/JSONValue.swift` に internal な `JSONValue` があり、接続設定の snapshot で `Encodable` / `Any` の値を写し取るのに使われている (`0102`)。`from(_:errorReason:)` / `fromDataChannels(_:errorReason:)` は `SoraError.configurationError(reason:)` を throw し、理由文字列は `0102` で `ConnectionConfigurationSnapshot.swift` の `ConfigurationSnapshotErrorReason` に集約済みである。

`RPCErrorDetail` を `@unchecked Sendable` にして警告を消すことはできるが、`Any?` が不変であることをコンパイラが検証できないため、この方法は採らない。

## 設計方針

- `RPCErrorDetail.data` の型を `Any?` から `JSONValue?` に変更する (`Sora/RPC.swift` の `data` の doc コメントも `JSONValue?` に合わせて書き換える)。JSON-RPC 2.0 の `error.data` は省略可能なので Optional を維持し、`error` に `data` key が無い場合は `nil`、`"data": null` の場合は `.null` にする。`errorObject["data"]` は `if let` で取り出し、key が存在する場合だけ変換する (`Any?` を `Any` へ暗黙変換して渡すと key 欠落が `Optional.none` の箱として `.null` に化け、暗黙変換の警告も増える)。
- `RPCErrorDetail` に internal な `init(code: Int, message: String, errorObject: [String: Any])` を追加し、エラー応答の辞書から `data` を変換する唯一の経路にする。`RPCChannel.handleMessage` はこの init を呼ぶ。実 `DataChannel` を用意せずに `@testable import Sora` のテストから検証できるようにするためである。
- `RPCErrorDetail` の宣言に `: Sendable` を明示する。`data` を `JSONValue?` に変えても公開型は暗黙に `Sendable` にならないため、準拠を宣言として示す。
- `Any` から `JSONValue` への変換は `Sora/JSONValue.swift` に internal の `JSONValue.fromJSONSerializationValue(_:) throws -> JSONValue` を追加して行う。値がトップレベルで文字列・数値・bool・null の場合でも直列化できるよう `JSONValueKey.value` の key を持つ辞書へ包み、`JSONSerialization.isValidJSONObject` で検証してから `JSONSerialization.data(withJSONObject:)` と `JSONDecoder().decode([String: JSONValue].self, from:)` で読む (`isValidJSONObject` はトップレベルの断片に対して false を返すため、包んでから検証する)。`fromDataChannels(_:errorReason:)` の変換もこの関数へ委譲し、直列化の手順を 1 箇所に集約する。
- `JSONSerialization.data(withJSONObject:)` は JSON にできない値 (`Date` など) に対して捕捉できない NSException を送出してプロセスを終了させるため、直列化の前に必ず `isValidJSONObject` で検証する。検証を通らない値には `EncodingError.invalidValue` を throw する。`JSONSerialization.data(withJSONObject:)` と `JSONDecoder.decode(_:from:)` が投げる error はそのまま伝播させる。独自のエラー型は作らず、RPC 固有の写像を `JSONValue` に持ち込まない。
- `init(code:message:errorObject:)` は変換に失敗した場合も `code` / `message` を失わず `data: nil` とし、英語のメッセージで `Logger.error(type: .dataChannel, ...)` を出す。この経路は `{"data": -1e999}` のように JSON の数値として表現できない値が届いた場合に到達する (`JSONSerialization.jsonObject` は `NSNumber` の `-inf` として返し、`isValidJSONObject` が false になる)。`["data": Date()]` を渡した場合も同じ経路になる。
- `init(code:message:errorObject:)` は struct 本体ではなく extension に置く。本体に init を書くと memberwise イニシャライザが合成されなくなり、テストで使う `RPCErrorDetail(code:message:data:)` が失われるためである。
- `JSONValue` を public にする。public な `RPCErrorDetail.data` の型に internal な型は置けないため、`data` の型変更には最小限の public 化が不可避である。公開するのは `public enum JSONValue: Sendable, Equatable`、enum case (case の公開範囲は enum に従うため `public` は書かない)、`Encodable` / `Decodable` の要件を満たす `public func encode(to:)` / `public init(from:)`、型と各 case の doc コメントに限る。
  - `extension JSONValue: Encodable` / `extension JSONValue: Decodable` に付いている `/// :nodoc:` を削除し、public にした witness が jazzy の出力に載るようにする。型 doc の「internal な値型です」も公開型の説明へ書き換える。
  - doc には次を書く。数値は `Decimal` 優先で復元され、`Decimal` で表現できない値だけ `double` になる。`Equatable` は case 込みで比較するため `.decimal(1) != .double(1.0)` である。`encode(to:)` した値を `init(from:)` で戻すと `.double(1.0)` は `.decimal(1)` になり等価にならない。`case .double(.nan)` は自分自身と等しくならない。
- `from(_:errorReason:)` / `fromDataChannels(_:errorReason:)` / `fromJSONSerializationValue(_:)` は internal のまま公開しない。`errorReason` を引数に取る SDK 内部向けの変換を公開 API にしないためである。
- `data` を読みやすくする利便 accessor (数値を `Double` で返す computed property など) と、`RPCErrorDetail` の public イニシャライザは追加しない。RPC のエラー詳細を読むための API 設計は `0109` が扱う。
- consumer package の `MediaChannelRPC.swift` には `func describeRPCError(_ error: Error)` を追加する。`RPCErrorDetail` を利用者が組み立てることはできないため、`guard let soraError = error as? SoraError, case .rpcServerError(let detail) = soraError else { return }` で受け取り、`switch detail.data` で `nil` と全 case を分岐する。
- 後方互換のない変更なので、`CHANGES.md` の `## develop` に `[CHANGE]` として記録し、次の `.0` リリースで取り込む。patch リリースには `[CHANGE]` を入れない運用であり (`## develop` には 0169 の `[CHANGE]` が既にある)、リリースタグが未定なので `Milestone:` 行は指定しない。

## スコープ外

- `JSONValue` の変換が throw するエラー型の分離と、`SoraError.configurationError` への写像を `ConnectionConfigurationSnapshot` 側へ移す作業。`from` / `fromDataChannels` を internal のままにするため公開 API に SDK 固有のエラー写像は現れず、`data` の型変更には不要である。分離は `0152` が公開設定型で必要になった時点で `0152` が扱う。
- `encodeParams` が `JSONSerialization` を経由して `Any` を作る経路は、`RPCChannel.call` の中で `Data` に直列化されるまでで同期の境界を越えないため、本 issue でも `0109` でも変更しない。`RPCRawResponse.result: Any` と `RPCRawResponse: @unchecked Sendable` は `0109` が新しい RPC 経路で排除する (`0109` の目的と完了条件に含まれている)。
- `0109` / `0110` / `0120` の新しい API の設計と実装 (`0109` は既存 `RPCErrorDetail` の宣言を変更しないと定めているが、本 issue が先に型と準拠を変える。`0109` の記述はその前提へ更新する)。
- `0152` の公開設定型。`0152` は本 issue が公開する `JSONValue` を前提にする。
- 公式ドキュメント (`sora-ios-sdk-doc`、別リポジトリ) の更新。Swift の例 (`source/swift/RequestSimulcastRidExample.swift` / `source/swift/PutSignalingNotifyMetadataItemExample.swift`) は `catch SoraError.rpcServerError(let detail)` の後に `_ = detail` とするだけで `data` を読まないため、型変更の影響を受けない。

## 変更対象

- `Sora/RPC.swift`: `RPCErrorDetail` の `Sendable` 準拠と `data` の型変更 (doc コメントを含む)、internal な `init(code:message:errorObject:)` の追加、`RPCChannel.handleMessage` の変更
- `Sora/JSONValue.swift`: `JSONValue` と `encode(to:)` / `init(from:)` の public 化、`/// :nodoc:` の削除、doc コメントの更新、internal な `fromJSONSerializationValue(_:)` の追加と `fromDataChannels(_:errorReason:)` の委譲
- `Sora/MediaChannel.swift`: `MediaChannel.rpc` の `- Throws` の `rpcServerError` に `data` の型を追記
- `SoraTests/RPCErrorDetailTests.swift`: internal な init と `fromJSONSerializationValue(_:)` の検証 (新規)
- `SoraTests/RpcE2ETests.swift`: server error 経路の検証
- `SoraTests/SendableConformanceTests.swift`: `RPCErrorDetail` の `requireSendable` と actor / Task 境界の表明
- `TestConsumers/Swift6Consumer/Sources/ConsumerCore/MediaChannelRPC.swift`: `data` を `JSONValue` として読む compile scenario と冒頭の「検査する契約」コメント
- `TestConsumers/Swift6Consumer/README.md`: `ConsumerCore` の契約と `MediaChannelRPC.swift` の担当欄
- `TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json` / `iphoneos26.5.info.txt`: `make api-baseline` による再生成
- `skills/sora-ios-sdk/SKILL.md`: `## Swift 6 と並行性` の `### Sendable 準拠` の一覧と `## RPC` の記述
- `CHANGES.md`: `## develop` の main の `[CHANGE]` と `[ADD]`
- `issues/0108-update-swiftpm-language-mode.md`: `## 前提となる issue` に本 issue を追加
- `issues/0118-refactor-e2e-concurrency-suppressions.md`: `## 前提となる issue` を新設して本 issue を追加
- `issues/0109-add-sendable-rpc-api.md`: 既存 `RPCErrorDetail` の型と準拠の記述を本 issue 完了後の状態へ更新
- `issues/0152-add-sendable-configuration-api.md`: `JSONValue` の public 化が実装済みであることと、変換エラーの写像の分離は `0152` が扱うことへ更新
- `issues/0120-add-sendable-statistics-api.md`: `0157` の状態を実装済みへ更新

## 前提となる issue

- `0123` (完了 2026-09-15): `SoraTests` の `requireSendable`。`SoraTests/SendableConformanceTests.swift` に internal 関数として実在し、本 issue の型検査でそのまま利用する。
- `0102` (完了 2026-09-16): `Sora/JSONValue.swift` の `JSONValue`。internal のまま完了しており、本 issue で public 化する。
- `0107` (完了 2026-09-24): consumer package による検証の基盤。`data` を `JSONValue` として読む compile scenario を置く先である。

### 本 issue の完了後に着手する issue

- `0108`: `Package.swift` を Swift 6 language mode へ移行する。検証方針にある「SDK target を strict concurrency / warnings-as-errors で build する」は、本 issue で警告を解消してから行う。
- `0118`: E2E test target の concurrency 診断抑止を除去する。
- `0109`: Sendable な RPC API を追加する。
- `0120`: Sendable な statistics snapshot API を追加する。本 issue が公開する `JSONValue` を前提にする。
- `0152`: Sendable な接続設定 API を追加する。本 issue が公開する `JSONValue` を前提にする。

## テスト方針

モックやスタブは使用しない。実際の Xcode 26.6 と `iphoneos26.5` で確認する。

- `SoraTests/RPCErrorDetailTests.swift` で internal な `init(code:message:errorObject:)` を実 Sora なしで検証する。`JSONSerialization.jsonObject` で実際の JSON-RPC エラー応答を読んでからこの init に渡し、次を網羅する。この init が `data` を `JSONValue` へ変換する唯一の経路なので、`data` の有無と値の型はここで決まる。
  - `data` key が無い場合は `nil`、`"data": null` の場合は `.null`
  - object / array / string / bool / 整数 / ネストした構造は、期待する `JSONValue` のリテラルと `XCTAssertEqual` で比較する
  - 小数は `JSONSerialization` が数値トークンを `NSNumber` (Double) として経由するため JSON の表記と `Decimal` の値が一致しない (実測では `0.1` が `.decimal(0.10000000000000001)` になる)。期待値は `Decimal(0.1)` のような浮動小数リテラルでは一致しないため、`Decimal(string: "0.10000000000000001")` のように文字列から作る
  - `["data": Date()]` のように JSON にできない値を渡した場合もクラッシュせず `data` が `nil` になること
- `SoraTests/RPCErrorDetailTests.swift` で `JSONValue.fromJSONSerializationValue(_:)` を直接検証する。object / array / string / bool / 整数 / 小数 / `NSNull` が期待する `JSONValue` になり、`1e300` は `.double` になり、`Date` のような JSON にできない値では `EncodingError.invalidValue` を throw すること
- `SoraTests/SendableConformanceTests.swift` に `requireSendable(RPCErrorDetail.self)` と `assertCrossesBoundaries(RPCErrorDetail(code:message:data:), ...)` を追加する。`requireSendable` は `@unchecked Sendable` でも通るため、checked であることは `RPCErrorDetail` へ `@unchecked Sendable` を付与していないことの差分で担保する。
- `make consumer-build` のあと、`Sora/` の全ファイルを Swift 6 言語モードで型検査する。判定は件数の絶対値ではなく差分で行い、`associated value 'rpcServerError(detail:)'` の警告が消えて他の警告が増えていないことを確認する。2026-09-24 の実測は主診断の warning 行が 54 件 (参考値)。
  ```
  xcrun swiftc -typecheck -swift-version 6 \
    -sdk "$(xcrun --sdk iphoneos26.5 --show-sdk-path)" \
    -target arm64-apple-ios14.0 \
    -I build/consumer/Build/Products/Release-iphoneos \
    -F build/consumer/Build/Products/Release-iphoneos \
    $(find Sora -name '*.swift')
  ```
- 実 Sora のテストサーバーで server error 応答を発生させ、`SoraError.rpcServerError(detail:)` として `code` / `message` が従来どおり取得できることと、返ってきた `data` を確認する。発生条件は `rpc_methods` で許可された `RequestSimulcastRid` を、サーバーが受理しない `params` (不要な項目を含む) で呼ぶことにする (Sora は `params` に不要な項目がある場合にエラーを返すと定めている)。server error にならない場合や `data` が付かない場合は、テストを失敗させずに理由と観測した応答を `## 検証記録` に残し、`data` の JSON の検証は単体テストで担保する。
- `make api-baseline` で再生成した baseline の差分をレビューし、`data` の型変更と `JSONValue` の追加・準拠以外の差分 (意図しない削除・変更) が無いことを確認する。その後 `make api-check-fresh` が成功することを確認する。
- `make consumer-build SCHEME=ConsumerCore` / `ConsumerUI` / `ConsumerLegacy`、`make consumer-check-negative`、`make fmt-lint`、`make lint` が違反 0 であることを確認する。
- feature branch の CI で `Build` / `Consumer Test` / `E2E Test` が成功することを確認する。

## 完了条件

- `RPCErrorDetail` が `Sendable` に準拠し、Swift 6 の型検査で `associated value 'rpcServerError(detail:)'` の警告が出ず、他の警告が増えていないこと
- `RPCErrorDetail.data` が `JSONValue?` で、`data` key の欠落が `nil`、`"data": null` が `.null` になることをテストで確認していること
- 入力の JSON の `data` がどの `JSONValue` の case と値で復元されるかを期待値として固定し、テストで確認していること (数値は `Decimal` 優先で復元されるため、`NSNumber` だった変更前とは表現が変わる。この差は `CHANGES.md` の `[CHANGE]` にも書く)
- 変換に失敗した場合も `code` / `message` を失わず `data` が `nil` になり、クラッシュしないことをテストで確認していること
- `@unchecked Sendable` を `RPCErrorDetail` へ付与していないこと
- `from(_:errorReason:)` / `fromDataChannels(_:errorReason:)` / `fromJSONSerializationValue(_:)` が internal のままで、公開 API に `errorReason` を引数に取る変換が現れていないこと
- `TestConsumers/Swift6Consumer/Sources/ConsumerCore/MediaChannelRPC.swift` の compile scenario が `JSONValue` の case 分岐で `data` を読めており、consumer の build が warnings-as-errors で成功すること
- 公開 API baseline を同じ変更で再生成し、`make api-check-fresh` が成功していること
- `CHANGES.md` の `## develop` の main で、既存の `[CHANGE]` (0169) の直後・最初の `[UPDATE]` より前に `[CHANGE]` (data の型変更で後方互換がないこと、`detail.data as? [String: Any]` が常に nil になること、数値が `JSONValue` の `decimal` / `double` で復元されるようになること、`JSONValue` の case 分岐への書き換え例) と `[ADD]` (JSON の値を表す公開型 `JSONValue` の追加) が `  - @t-miya` 付きで並んでいること
- `skills/sora-ios-sdk/SKILL.md` の `## Swift 6 と並行性` の `### Sendable 準拠` に `RPCErrorDetail` と `JSONValue` が載り、`## RPC` に server error の `data` が `JSONValue?` であることと読み方の例があること
- `TestConsumers/Swift6Consumer/README.md` の契約一覧と担当欄が新しい scenario と一致していること
- `issues/0108` / `issues/0118` / `issues/0109` / `issues/0152` の記述が本 issue の完了を前提とした状態に更新されていること
- 実 Sora の server error 経路の検証結果 (発生条件と応答、または server error を発生させられなかった事実と試した呼び出し) が `## 検証記録` にあること
- iOS 14 deployment target と package product / target / binary dependency の構成が変わっていないこと
- 追加したテストと既存テストがすべて成功し、feature branch の CI が成功すること

## 検証記録

- 2026-09-24: `Sora/` を Swift 6 言語モードで型検査し、主診断の warning 行が 54 件から 53 件に減った。`associated value 'rpcServerError(detail:)' of 'Sendable'-conforming enum 'SoraError' contains non-Sendable type 'RPCErrorDetail'` は消え、新規の警告は 0 件だった
- 2026-09-24: `SoraTests/RPCErrorDetailTests.swift` (8 件) と `SoraTests/SendableConformanceTests.swift` (5 件) を iOS Simulator (iPhone 17 Pro / iOS 26.5) で実行し、13 件すべて成功した。`data` key の欠落が `nil`、`"data": null` が `.null`、整数 / 小数 / 文字列 / bool / 配列 / 辞書 / `1e300` (`.double`) が対応する case に変換され、`{"data": -1e999}` と `["data": Date()]` ではクラッシュせず `data` が `nil` になり、`JSONValue.fromJSONSerializationValue` が `EncodingError.invalidValue` を投げることを確認した
- 2026-09-24: `make build` (`SWIFT_VERSION=6`) が成功した
- 2026-09-24: `make consumer-build SCHEME=ConsumerCore` / `ConsumerUI` / `ConsumerLegacy`、`make consumer-check-negative`、`make fmt-lint`、`make lint` が成功した (consumer は warnings-as-errors で build)
- 2026-09-24: `make api-baseline` で再生成した baseline の差分をレビューし、削除は `RPCErrorDetail.data` の `Any?` (型と `usr` / `mangledName`) だけで、追加は `JSONValue` の公開と `RPCErrorDetail` の `Sendable` 準拠だった。`make api-check-fresh` が `The committed API baseline matches the current Sora module.` を出力して成功した
- 実 Sora の server error 経路の検証は feature branch の CI で行う (ローカルに Sora のテストサーバーがないため)

## 解決方法
