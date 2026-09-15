# 公開値型を `Sendable` に対応させる

- Created: 2026-08-27
- Completed:
- Priority: Medium
- Branch: feature/update-sendable-value-conformances
- Polished: 2026-09-15

## 目的

deep Sendable な公開値型へ checked `Sendable` 準拠を追加し、Swift 6 consumer が actor / Task 境界で SDK の値をそのまま利用できるようにする。

`0102` (接続設定の snapshot 化) と `0152` (公開 Sendable 設定型) は、公開型が `Sendable` であることを前提に、公開型を写した mirror 型を作らずに snapshot と設定型を組み立てる。本 issue を両 issue より先に完了させる。

`Sendable` が値型へ要求するのは immutability ではなく、stored property と associated value が再帰的に `Sendable` であることである。`MediaConstraints` のように `public var` を持つ型も、保持する値がすべて `Sendable` なら対象に含める。

mutable reference、`Any` / `Encodable?` などの存在型、closure、raw WebRTC object を含む型へ `@unchecked Sendable` を付与して一括対応しない。

## 現状

`Sora/` 配下の `public enum` / `public struct` は全部で 80 型ある。本 issue の対象と対象外は次のとおりである。

### `Sendable` を付与済み (16 型)

`Role` / `AudioCodec` / `VideoCodec` / `Rid` / `SimulcastRid` / `SimulcastRequestRid` / `SpotlightRid` / `ICETransportPolicy` / `SDPSemantics` / `AspectRatio` / `WebSocketStatusCode` / `TLSSecurityPolicy` / `SignalingRole` / `DeviceInfo` / `Proxy` / `CameraSettings.Resolution`

`skills/sora-ios-sdk/SKILL.md` の `Sendable` 準拠一覧は、このうち `TLSSecurityPolicy` と `SignalingRole` を欠いた 14 型しか載っていない。本 issue で 16 型 + 29 型 = 45 型へ揃える。

### 本 issue で `Sendable` を付与する (29 型)

deep Sendable であるにもかかわらず `Sendable` が付いていない型である。すべて checked `Sendable` を付与できることを、実際の `Sora/` のソースへ conformance を足した Swift 6 型検査で確認済みである。

- `Sora/ConnectionState.swift`: `ConnectionState`
- `Sora/WebRTCConfiguration.swift`: `MediaConstraints` / `DegradationPreference`
- `Sora/AudioMode.swift`: `AudioMode` / `AudioOutput`
- `Sora/Logger.swift`: `LogType` / `LogLevel` / `Log` / `Logger.Group`
- `Sora/VideoView.swift`: `VideoViewConnectionMode`
- `Sora/WebSocketChannel.swift`: `WebSocketMessage`
- `Sora/Sora.swift`: `ConnectionTask.State`
- `Sora/Configuration.swift`: `Configuration.Spotlight` / `ForwardingFilterRuleField` / `ForwardingFilterRuleOperator` / `ForwardingFilterAction` / `ForwardingFilterRule`
- `Sora/CameraVideoCapturer.swift`: `CameraSettings`
- `Sora/MediaChannel.swift`: `SoraCloseEvent`
- `Sora/Signaling.swift`: `SignalingAnswer` / `SignalingUpdate` / `SignalingReOffer` / `SignalingReAnswer` / `SignalingSwitched` / `SignalingRedirect` / `SignalingClose` / `SignalingPing` / `SignalingPong` / `SignalingDisconnect`

補足する判断材料は次のとおりである。

- `MediaConstraints` は `public var mandatory` / `public var optional` を持つが、保持するのは `[String: String]` だけなので deep Sendable である。
- `MediaConstraints` / `DegradationPreference` / `ForwardingFilterRule` 系 / `CameraSettings` は `0102` が snapshot へそのまま保持するため、対象一覧から外せない。`0102` は本 issue の完了に合わせて `CameraSettings` を直接保持する形へ更新済みである。`Configuration.Spotlight` は `0102` では `Configuration` の stored property である `isSpotlightEnabled: Bool` を凍結するため使わないが、deep Sendable な公開値型として本 issue の対象に含める。
- `AudioMode` の `AVAudioSession.Category` と `CameraSettings` の `AVCaptureDevice.Position` は imported type だが、iPhoneOS 26.5 SDK で `Sendable` であることを型検査で確認済みである。`build.yml` が使う iPhoneOS 26.2 SDK でも同じ結果になることを実装時に確認する。
- `SoraCloseEvent` の `case error(Error)` は、採用 toolchain の stdlib で `Error` が `Sendable` を継承しているため checked `Sendable` にできる。ただし運ばれる `Error` の実体まで deep Sendable であることは保証しない。
- `SignalingAnswer` など 10 型は `String` / `Bool?` / `Int` だけで構成されている。`Signaling` という集合で一括して「付与できない」と扱うのは誤りである。
- `CameraSettings` へ `Sendable` を付与すると、`Sora/VideoMute.swift` の internal `CameraSettingsSnapshot` の存在理由 (非 `Sendable` な `CameraSettings` を actor 境界へ渡すための写し) が失われる。`0102` の見直しは本 issue の branch で行った。`CameraSettingsSnapshot` の削除と `0142` の見直しは本 issue のスコープ外とする。

### 本 issue では付与しない

- `Configuration`: `Encodable?` (metadata 系 7 個) / `Any?` (`dataChannels`) / mutable class の `ICEServerInfo` / handler bag を含む。snapshot 化と公開設定型は `0102` / `0152` が扱う。
- `WebRTCConfiguration`: 阻害要因は `iceServerInfos: [ICEServerInfo]` だけで、`ICEServerInfo` が mutable な `public final class` であることによる。snapshot 化は `0102` が扱う。
- `ForwardingFilter`: `metadata: Encodable?` を含む。`0102` の `ForwardingFilterSnapshot` が扱う。
- `Signaling` 本体 / `SignalingConnect` / `SignalingOffer` / `SignalingCandidate` / `SignalingNotify` / `SignalingNotifyMetadata` / `SignalingPush`: `Any?` / `Encodable?` / mutable class の `ICECandidate` を含む。event API は `0110` が扱う。
- `SignalingOffer.Configuration`: `[ICEServerInfo]` を含む。`SignalingOffer.Encoding`: raw WebRTC object の `RTCResolutionRestriction` を含む。どちらも `0110` が扱う。
- `RPCErrorDetail` / `RPCResponse` / `RPCTypes` の params と result、および RPC method の enum (`RequestSimulcastRid` / `RequestSpotlightRid` / `ResetSpotlightRid` / `PutSignalingNotifyMetadata` / `PutSignalingNotifyMetadataItem`): Sendable な RPC API は `0109` が扱う。`0109` は既存の `RPCMethodProtocol` / `RPCResponse` / `RPCErrorDetail` を変更せずに新しい Sendable な RPC API を追加し、旧 API の削除は次期 major version で行う。method enum はケースを持たないが、新しい RPC protocol 契約の一部であるため本 issue では扱わない。`RPCErrorDetail.data: Any?` は `0157` が扱う。
- `Statistics` / `StatisticsEntry`: public class。`0120` が Sendable な snapshot API を追加する。
- `VideoFrame`: raw WebRTC object を含む (`0027` / `0105`)。
- `ICEServerInfo`: public final class (`0102` の snapshot 化で扱う)。
- `ICECandidate`: public final class で `public var url` / `public var sdp` を持つため、値型への準拠追加では解決できない。`0110` の event payload から外す対応と合わせて判断する。
- `ScreenCaptureSettings`: `videoSampleBufferTransformer` / `onRuntimeError` の closure を 2 つ持つ。Sendable な設定型は未起票である。
- `SoraError`: `Error` 準拠により暗黙に `Sendable` とみなされるが、`case rpcServerError(detail: RPCErrorDetail)` の associated value が non-Sendable であり、現行ソースの Swift 6 型検査で既に警告が出ている。`RPCErrorDetail` の置き換えは `0157` が扱う。
- `SDKInfo` / `WebRTCInfo` / `Utilities` / `MediaStreamAudioVolume`: ケースを持たずインスタンスが存在しない namespace 専用の enum なので、`Sendable` に意味が無い。
- `SoraDispatcher`: `0116` で非推奨化し `0117` で削除するため対象に含めない。

上の 3 つの区分は `Sora/` の 80 型を重複なく覆う (16 型 + 29 型 + 35 型)。「本 issue では付与しない」には、80 型に含まれない public class のうち `Sendable` の判断が必要なもの (`Statistics` / `StatisticsEntry` / `ICEServerInfo` / `ICECandidate`) も理由付きで挙げている。

## 設計方針

- `Sora/` 配下の `public enum` / `public struct` を機械的に抽出する。抽出規則は「`Sora/` 配下の `.swift` で `public struct` / `public enum` を宣言している行 (入れ子型を含み、コメント行を除く)」とし、`Sora/` 全体で 80 型になる。この 80 型について stored property と associated value を再帰的に確認する。deep Sendable かどうかの判定は「値型であり、保持する値と associated value が再帰的に `Sendable` であり、mutable class、`Any` / `Any?` / `Encodable?` などの存在型、closure、`NSObject`、raw WebRTC object を含まないこと」とする。`public var` の有無は判定に影響しない。
- deep Sendable と判定した型へ checked `Sendable` を付与する。public 非 frozen 型へは `Sendable` が推論されないため明示的に書く。
- `Sendable` 準拠は型の宣言と同じファイルにしか書けない。`extension` は対象型の宣言と同じファイル内に置く。
- `@unchecked Sendable` を value type へ新たに付与しない。`Sora/` の内部の値型に既存の付与が 5 件ある (`CameraCaptureFormatBox` / `RPCRawResponse` / `ScreenCaptureController` の `RecorderOperationResult` と `RecorderStartResult` / `SenderStreamBox`) が、本 issue では削除しない。
- imported type を associated value に持つ型は、iPhoneOS SDK の header と swiftinterface を確認し、`swiftc -typecheck` で表明してから付与する。WebRTC の header に `NS_SWIFT_SENDABLE` は無いため、raw WebRTC object を持つ型は対象外とする。
- `Sendable` の追加は marker protocol の適合追加であり、`Codable` / `CustomStringConvertible` / `Equatable` / `RawRepresentable` の合成と実装、および実行時の挙動を変えない。既存テストで回帰を確認する。
- `Log` を `Sendable` にすると、利用者が handler 経由で受け取った `Log` を任意スレッドから `description` 化できるようになる。`Log.description` が使う共有 `DateFormatter` の thread-safety の根拠は `0106` が扱う。本 issue は準拠の追加だけを行い `0106` と整合させる。
- checked であることの保証は Swift 6 言語モードでのみ成立する。SwiftPM の consumer は `Package.swift` の `swift-tools-version` により Swift 5 言語モードで build されるため、`0108` の完了までは consumer 側で警告に留まる。
- public conformance の追加は、利用者が対象型へ独自に `Sendable` を付与していた場合に重複適合の警告になる。`extension X: Sendable {}` / `extension X: @retroactive Sendable {}` / `extension X: @unchecked Sendable {}` のいずれでも `conformance of 'X' to protocol 'Sendable' was already stated in the type's module` の警告になり、warnings-as-errors を有効にしている利用者は build に失敗する。この影響を `CHANGES.md` に追記する。
- 実装コードとテストのコメントには issue 番号を書かない。理由そのもの (non-Sendable な `Any?` を持つ、closure を持つ等) を書く。

## スコープ外

- `@unchecked Sendable` を付与している class の整理は個別 issue が扱う (`CameraVideoCapturer` は `0103`、`Logger` は `0106`、`Sora` は `0111`)。`ConnectionTimer` と `NativePeerChannelFactory` は担当が未定である。
- `SoraError` と `RPCErrorDetail` の Sendable 診断の解消は `0157` が扱う。
- `CameraSettingsSnapshot` の削除。
- `Configuration` / `WebRTCConfiguration` の snapshot 化と公開 Sendable 設定型は `0102` / `0152` が扱う。
- `LogType.configurationViewController` と `Logger.Group.configurationViewController` の削除は公開 enum のケース削除であり後方互換がないため行わない。
- `AudioMode` への種類追加の検討は `0149` (pending) が扱う。
- Sendable 非準拠の型を検出する CI gate の追加は `0107` / `0118` が扱う。
- `0102` の `CameraSettings` を snapshot へそのまま保持する形への更新と、`0143` の `CameraSettings` が `Sendable` になったことを前提にした記述更新は、本 issue の branch で行った。`0142` は `CameraSettingsSnapshot` へ新しい設定を引き継ぐ方針のため変更しない。`CameraSettingsSnapshot` の削除は別 issue とする。

## 変更対象

- `Sora/ConnectionState.swift` / `Sora/WebRTCConfiguration.swift` / `Sora/AudioMode.swift` / `Sora/Logger.swift` / `Sora/VideoView.swift` / `Sora/WebSocketChannel.swift` / `Sora/Sora.swift` / `Sora/Configuration.swift` / `Sora/CameraVideoCapturer.swift` / `Sora/MediaChannel.swift` / `Sora/Signaling.swift`: 「本 issue で `Sendable` を付与する」に挙げた 29 型への準拠追加
- `SoraTests/SendableConformanceTests.swift` (新規): 対象 29 型のコンパイル時表明と actor / Task 境界の受け渡し
- `skills/sora-ios-sdk/SKILL.md`: `Sendable` 準拠の一覧を更新
- `CHANGES.md`

## 前提となる issue

- `0107` (未完了): consumer fixture と API baseline。`0107` の完了前に着手する場合は、本 issue で `SoraTests` に新設する `requireSendable` と `git diff` の目視で代替し、consumer fixture と API baseline による機械検査は `0107` の完了後に追加する。

### 本 issue を前提とする

- `0102`: `ConnectionConfigurationSnapshot` が `MediaConstraints` / `DegradationPreference` / `ForwardingFilterRule` 系をそのまま保持する。`CameraSettings` と `Configuration.Spotlight` も写しを作らずに保持できるようになるため、`0102` の `CameraSettingsSnapshot` と Bool 復元の記述は本 issue の完了後に更新する。
- `0152`: 利用者が actor / Task 境界へ渡す公開 Sendable 設定型が本 issue の準拠を利用する。
- `0124` / `0125`: samples / quickstart の `@preconcurrency import Sora` と `nonisolated(unsafe)` を撤去する際の公開 `Sendable` 一覧。

### 関連する issue

- `0106`: `Logger` 本体の `@unchecked Sendable` と `nonisolated(unsafe)` の除去。`Log` の `description` が使う共有 `DateFormatter` の thread-safety の根拠も `0106` が扱う。順序は問わない。
- `0108`: `Package.swift` の Swift 6 language mode 化。SwiftPM の consumer で checked が効くようになるのは `0108` の完了後である。
- `0110`: Sendable な event API。`Signaling` 本体 / `SignalingCandidate` / `ICECandidate` の扱いを `0110` と揃える。
- `0116` / `0117`: `SoraDispatcher` の非推奨化と削除。
- `0102`: 本 issue の branch で、`CameraSettings` を snapshot へそのまま保持する形へ更新した。`Configuration.Spotlight` は `0102` では使わない (`Configuration` の stored property である `isSpotlightEnabled: Bool` を凍結する)。
- `0143`: 本 issue の branch で、`CameraSettings` が `Sendable` になったことを前提にした記述へ更新した。
- `0142`: `CameraSettingsSnapshot` へ新しい設定を引き継ぐ方針は `CameraSettings` が `Sendable` になっても変わらないため変更しない。`CameraSettingsSnapshot` の削除は別 issue とする。

## テスト方針

モックやスタブは使用しない。

- `SoraTests/SendableConformanceTests.swift` (新規) に `func requireSendable<T: Sendable>(_: T.Type) {}` を置き、対象 29 型すべてについて呼ぶ。準拠が無ければコンパイルが失敗する。
- `requireSendable` は `@unchecked Sendable` でも通るため、checked であることの根拠にはしない。checked であることは、対象型へ `@unchecked Sendable` を付与していないことを `git diff` で確認して担保する。
- `SoraTests` 側で対象型へ `Sendable` を付与する extension を書かない。書くと検査が無意味になる。
- 対象型の値を `nonisolated` な (MainActor ではない) actor の stored property と `Task` の closure へ渡すテストを置く。
- `xcodebuild build-for-testing -scheme Sora-Package` を `SWIFT_VERSION=6` で実行し、test target まで含めて build する。
- `Sora/` 全体を `swiftc -typecheck -swift-version 6` で検査し、concurrency の警告が増加しないことを確認する。実測では現行ソースが 0 error / 64 warning で、対象 29 型を含む付与を行った検証では 1 件 (`PeerChannel` の `SignalingPong` capture) が解消し、新たに増えた警告は 0 件だった。確認は CI と同じ toolchain (`build.yml` は Xcode 26.2 / iphoneos26.2、`ci.yml` は iphoneos26.5) で行う。warnings-as-errors を gate にするのは `0107` / `0108` / `0118` である。
- 既存テスト (`RidTests` / `SignalingConnectTests` / `ConfigurationTests` / `SignalingOfferEncodingTests` など) がすべて成功することを確認する。
- 公開 API の差分を `git diff` と目視で確認し、準拠の追加以外の変更が無いことを確かめる。

## 完了条件

- 「本 issue で `Sendable` を付与する」に挙げた 29 型が checked `Sendable` に準拠していること。
- `requireSendable` と actor / Task 境界のテストが `SWIFT_VERSION=6` でコンパイル・成功すること。
- 対象 29 型へ `@unchecked Sendable` を付与していないこと。
- `Sora/` の Swift 6 型検査で concurrency の警告が増加していないこと。
- 公開 API の差分が `Sendable` 準拠の追加だけであること。
- `skills/sora-ios-sdk/SKILL.md` の `Sendable` 準拠一覧が「`Sendable` を付与済み」16 型と「本 issue で `Sendable` を付与する」29 型を合わせた 45 型に一致していること。
- `CHANGES.md` の `## develop` に `[UPDATE]` として追記し、利用者が独自に追加していた `Sendable` 準拠の削除が必要である旨を明記していること。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
