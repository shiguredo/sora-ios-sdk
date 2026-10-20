# 利用者が actor / Task 境界へ渡せる公開 Sendable 設定型を追加する

- Created: 2026-09-15
- Completed:
- Priority: Medium
- Branch: feature/add-sendable-configuration-api
- Polished: 2026-10-01

## 目的

Swift 6 言語モードの利用者が、接続設定を actor / Task 境界へ安全に渡せる公開型を追加する。

`0123` は `Configuration` を「`Sendable` を付与できない型」に分類し、unsafe な型の受け皿を `0102` / `0109` / `0110` / `0120` の snapshot / v2 API としている。`0109` (完了 2026-09-30) は RPC の受け皿を実装済みで、`MediaChannel.sendableRPC` / `SendableRPCMethodProtocol` / `SendableRPCResponse` / `SendablePutSignalingNotifyMetadata` / `SendablePutSignalingNotifyMetadataItem` が公開されている。設定値については `0102` が導入する `ConnectionConfigurationSnapshot` が internal に留まり、`0110` / `0120` は event / statistics が対象で、公開 Sendable な設定型を提供する issue が存在しない。

`2026-10-01` の実測 (Swift 6.3.3 / Xcode 26.6) では、`Configuration` を actor / Task 境界へ渡す需要はリポジトリ内の利用側と隣接リポジトリでは確認できなかった。利用側は `Configuration` を保持・移送せず、組み立てて `Sora.connect` へ渡すだけであり、実 SDK に対する 31 プローブでも境界越えの診断は脱出する `@Sendable` クロージャへのキャプチャなど限られた形でしか出なかった (詳細は「実測: 境界越えの需要」)。このため本 issue の必要性の根拠は「利用者が困っている」ことではなく、`0102` が確定した `Configuration` のフィールド分類 (そのまま値で持つ / 変換して持つ / 含めない) のうち「変換して持つ」の結果を、SDK 内部の snapshot だけでなく公開 API としても明示する設計の一貫性に置く。

## 現状

`Sora/Configuration.swift` の `Configuration` は次の理由で `Sendable` にできない。

- `signalingConnectMetadata` / `signalingConnectNotifyMetadata` / `audioOpusParams` / `videoVp9Params` / `videoAv1Params` / `videoH264Params` / `videoH265Params` の `Encodable?`
- `dataChannels: Any?`
- `forwardingFilter` / `forwardingFilters` と `ForwardingFilter.metadata: Encodable?`
- 可変 class の `ICEServerInfo`、`webSocketChannelHandlers`、`mediaChannelHandlers`
- raw WebRTC object の `audioDevice`

`0102` は接続開始時にこれらを internal な `ConnectionConfigurationSnapshot` へ写し取る (handler bag と `audioDevice` は snapshot へ含めず、明示引数として引き渡す) が、internal のため通常の consumer は `import Sora` から参照できない。`0107` の consumer package は `@testable` と `@preconcurrency` を禁止しており、internal 型を検証対象にできない。

## 実測: 境界越えの需要

`Configuration` を actor / Task 境界へ渡す需要を `2026-10-01` に実測した (Swift 6.3.3 / Xcode 26.6)。結果は次の 3 つの範囲のいずれでも需要を確認できなかった。

### 1. リポジトリ内の利用側

- `TestConsumers` (`ConsumerCore` / `ConsumerUI` / `ConsumerLegacy` / `ConsumerSwift5`) / `SoraTests` / `skills/sora-ios-sdk/SKILL.md` に、`Configuration` を保持・移送している箇所は 0 件。すべて「組み立てて `Sora.connect` へ渡すだけ」または `inout Configuration` である (`TestConsumers/Swift6Consumer/Sources/ConsumerCore/ConnectSignaling.swift` の `makeConfiguration` / `connectToSora`、`HandlerCompatibility.swift` の `attachHandlers`、`SoraTests` の各接続ヘルパー、`SKILL.md` の接続手順)
- `nonisolated(unsafe)` は `Configuration` には 1 箇所も使われていない。`TestConsumers` / `SoraTests` に `Configuration` を運ぶ `nonisolated(unsafe)` は無く、`SKILL.md` が例として示す `nonisolated(unsafe) let` の対象は `MediaChannel` / `MediaStream` である
- SDK 自身は `0102` の internal な `ConnectionConfigurationSnapshot` で境界越えを実装・テスト済み。`SoraTests/SendableConformanceTests.swift` の `testConnectionConfigurationSnapshotTypesConformToSendable` が `ConnectionConfigurationSnapshot` / `ICEServerSnapshot` / `WebRTCConfigurationSnapshot` / `ForwardingFilterSnapshot` を actor (`SendableBoundaryProbe`) と `Task` の境界へ渡している

### 2. 隣接リポジトリ (sora-ios-sdk-samples / sora-ios-sdk-quickstart)

- sora-ios-sdk-samples: すべて静的ファクトリまたは `@MainActor` の ViewController で `Configuration` を組み立て、`SoraSDKManager.shared.connect(configuration:)` / `Sora.shared.connect(configuration:)` へ渡すだけである。`@Sendable` 完了クロージャが捕捉するのは `self` と `MediaChannel` で、`Configuration` ではない。samples 側の source に `Task.detached` は 0 件
- sora-ios-sdk-quickstart: `ViewController.connectionQueue` 上で `Configuration` を組み立てて `Sora.shared.connect(configuration:)` へ渡すだけである。`nonisolated(unsafe)` は `MediaChannel` を運ぶ closure と ViewController 参照が対象で、`Configuration` は含まれない

### 3. 実 SDK に対する最小プローブ

実 SDK を `import` して `Configuration` を組み立て、境界へ渡す形を 31 通り用意し、Swift 6 / Swift 5 の両言語モードで `swiftc -typecheck` に掛けて診断の有無を確認した (下表は Swift 6 言語モードの結果で、「診断あり」は error として出たものを指す)。負のコントロールとして、SDK に依存しないローカルな非 Sendable 型で同じ 31 通りを書き、同じ形の診断が出ることを確認し、診断が握り潰されていないことを確かめた。

| `Configuration` の渡し方 | 診断 |
| --- | --- |
| `@MainActor` で組み立てて `Sora.connect` を呼ぶ | なし |
| `actor` の stored property に持つ | なし |
| `Task.detached` の closure でキャプチャする | なし |
| `actor` のメソッド引数へ渡す | なし |
| `nonisolated` な async 関数の引数へ渡し、`@MainActor` から `await` する | なし |
| 脱出する `@Sendable` クロージャでキャプチャする | あり (`SendableClosureCaptures`) |
| 利用者自身の `Sendable` 準拠型の stored property へ格納する | あり (`stored property ... has non-Sendable type`) |
| `@MainActor` の stored property を別の isolation domain から読む | あり |
| `Task.detached` の結果として受け取る | あり (`Task<Configuration, Never>` が main actor 隔離領域を出られない) |
| mutation を伴う同時実行キャプチャ | あり |

- `sending ... risks causing data races` は 31 プローブ中 1 件も出なかった
- `nonisolated(nonsending)` は本環境の既定ではない (`swiftc -print-supported-features` で `NonisolatedNonsendingByDefault` は `enabled_in: 7`)。「単一用途の非 Sendable 値の移送と actor 境界への引数渡しを診断しない」という Swift 6.3.3 の挙動として記録する。機序は特定しておらず、これを診断が出ない原因として断定しない
- この実測が示すのは「リポジトリ内の利用側、隣接リポジトリ、および代表的な 31 通りでは需要を確認できなかった」ことまでである。一般の利用者に需要が無いことの証明ではない

## 設計方針

- 内部型である `ConnectionConfigurationSnapshot` をそのまま公開しない。内部都合の変更が公開 API の互換性を縛るためである。
- 公開設定型のフィールドは `Configuration` の全 stored property を対象とし、`0102` が確定した snapshot のフィールド分類 (そのまま値で持つ / 変換して持つ / 含めない) を再利用する。分類の内訳と根拠は `0102` を引き継ぐ。
- `Encodable?` の metadata 系 7 個 (`signalingConnectMetadata` / `signalingConnectNotifyMetadata` / `audioOpusParams` / `videoVp9Params` / `videoAv1Params` / `videoH264Params` / `videoH265Params`)、`ForwardingFilter.metadata`、`Any?` の `dataChannels` は公開 `JSONValue?` として保持する。`Sora/JSONValue.swift` の `JSONValue` は `0157` の実装により public になっているため、本 issue はそれをそのまま使う。
- `webRTCConfiguration` と `forwardingFilter` / `forwardingFilters` は、既存の `WebRTCConfiguration` / `ForwardingFilter` をそのままは保持できない (`0123` が両型を `Sendable` を付与しない型に分類しており、`WebRTCConfiguration` は可変 class の `ICEServerInfo` を、`ForwardingFilter` は `metadata: Encodable?` を含む)。`0102` の分類と同じく変換して持ち、公開設定型の中で deep Sendable な公開値型として表す。内訳のうち `Sendable` な既存公開型 (`MediaConstraints` / `DegradationPreference` / `SDPSemantics` / `ICETransportPolicy` / `ForwardingFilterRule` 系。`0123` で `Sendable` になった型と以前から `Sendable` だった型の混在である) は mirror 型を定義せずそのまま保持し、`ICEServerInfo` と `ForwardingFilter.metadata` だけを写す。`ICEServerInfo` の写し先は URL / username / credential / TURN-TLS ポリシーを持つ deep Sendable な公開値型とし、フィールド分類は `0102` の `ICEServerSnapshot` と同じにする。
- 公開設定型は deep Sendable な値だけで構成し、handler (`webSocketChannelHandlers` / `mediaChannelHandlers`) を含めない。event の購読は `0110` の Sendable event API が担う。`audioDevice` は internal のため公開設定型では表現せず、`requiresStereoAudioSDP` は `audioDevice` が公開利用者では常に nil であることから `audioStereoOutputEnabled` と同じ値として扱う。
- `Sora.connect` に新しい overload を追加し、既存の `connect(configuration:webRTCConfiguration:handler:)` は維持する。新 overload は公開設定型から `ConnectionConfigurationSnapshot` を直接構築し、metadata / `dataChannels` は公開設定型が保持する `JSONValue` をそのまま写す。`Configuration` へ復元してから `0102` の変換を再実行する経路は採らない (`dataChannels` の変換が `JSONSerialization` なため、`JSONValue` を受理せず失敗する)。公開設定型から `Configuration` への復元は `MediaChannel.configuration` の互換のためにだけ用意し、snapshot 生成には使わない。
- 既存 `Configuration` から公開設定型への変換経路を用意し、利用者が段階的に移行できるようにする。変換は metadata などの encode に失敗し得るため、失敗時のエラー型と `SoraError.configurationError` への写像は本 issue が設計する (`0157` で `JSONValue` は public になったが、変換関数は internal のままで、公開型に SDK 固有のエラー写像と理由文字列を抱え込ませない設計は本 issue が扱う)。
- `0102` の完了を前提とする。`0102` が確定する snapshot のフィールド分類を再利用する。
- 本 issue は handler を公開設定型に含めないため、単独では `Configuration` を置き換えられない。handler bag の扱いは `0110`、`audioDevice` の扱いは `0102` の範囲であり、`0110` (event) / `0120` (statistics) が完了して初めて、actor の中で接続から event / statistics の処理までを `Configuration` なしで完結させられる形になる。RPC は `0109` (完了 2026-09-30) でこの形が成立している。

## 前提となる issue

- `0102` (完了 2026-09-16): 内部 snapshot の型と変換。フィールド分類を本 issue の設計に再利用する。
- `0110`: handler を Sendable な event API として提供する。公開設定型から handler を除外する前提である。
- `0123` (完了 2026-09-15): 公開 value type への `Sendable` 準拠。公開設定型がそのまま保持する型の前提である。
- `0107` (完了 2026-09-24): consumer package による strict concurrency 検証の基盤。
- `0157` (実装済み): `JSONValue` の public 化。metadata / `dataChannels` / `ForwardingFilter.metadata` の表現に使う。

### 順序調整

- `0157` の実装で公開 `JSONValue` が存在する。本 issue は公開設定型と、`Configuration` からの変換経路で使う変換エラーの設計を扱う。
- `0107` は完了しており、`TestConsumers/Swift6Consumer` の consumer package と gate が存在する。完了条件の compile scenario 検証はこの package で行う。

## スコープ外

- `0109` (完了 2026-09-30) / `0110` / `0120` の API (RPC / event / statistics) の設計と実装。
- `0153` が扱う、`Sora.connect` の `webRTCConfiguration` 引数と `Configuration.webRTCConfiguration` の一本化。本 issue は新 overload の追加のみで、既存 overload の引数は変更しない。
- 既存 `Configuration` の非推奨化と削除 (後方互換のない変更)。

## 完了条件

- 公開 Sendable な設定型が追加され、利用者が actor / Task 境界で設定値を渡せること (実測した需要は限定的であり、目的は `0102` の分類を公開 API として明示することにある。「実測: 境界越えの需要」を参照)。
- 設定型が handler を含まず、deep Sendable であること。
- `Configuration` から公開設定型への変換で、metadata / `dataChannels` / codec 別 params / `ForwardingFilter` / WebRTC 設定の値が失われておらず、公開設定型から `Configuration` への復元で同じ接続設定になること。
- `0107` の consumer package へ公開設定型の compile scenario を追加し、consumer package の gate (Swift 6 言語モードと warnings-as-errors) により compile できること (strict concurrency は Swift 6 言語モードで complete 相当になるため `SWIFT_STRICT_CONCURRENCY` は設定しない。`0107` の決定)。
- 公開設定型が無いと困ることを示す consumer package の負例は、脱出する `@Sendable` クロージャへ `Configuration` をキャプチャする形 (`NegativeChecks/core-sendable-capture.swift` が `MediaChannel` で使っている形と同じ)、または利用者自身の `Sendable` 準拠型の stored property へ `Configuration` を格納する形で作れること。`Configuration` を非脱出の文脈 (`@MainActor` で組み立てて `Sora.connect` へ渡す、`actor` のメソッド引数へ渡す、`nonisolated` な async 関数の引数へ渡すなど) で渡す形では診断が出ず負例にならない (実測)。`EXPECT-DIAGNOSTIC` の group 名は推測せず `swiftc -typecheck` の出力から確定する (`TestConsumers/Swift6Consumer/README.md` の負例の追加手順)。
- 公開設定型・公開 ICE サーバー値型・`Sora.connect` の新 overload の追加に伴い、同じ変更で `make api-baseline` を実行して `TestConsumers/Swift6Consumer/ApiBaseline/` を再生成し、`make api-check-fresh` が成功すること (API の追加は `make api-check` では検出できず、`api-check-fresh` が検出する。`CODEBASE.md` の規約)。
- 既存の `Configuration` と `Sora.connect` の公開 API が維持されていること。
- `CHANGES.md` に `[ADD]` として追記していること。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
