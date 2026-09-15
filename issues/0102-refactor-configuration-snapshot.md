# 接続設定を immutable な Sendable snapshot へ変換する

- Created: 2026-08-27
- Completed:
- Priority: Medium
- Branch: feature/refactor-configuration-snapshot
- Polished: 2026-09-15

## 目的

接続開始時に利用者の `Configuration` を immutable かつ deep Sendable な内部 snapshot へ変換し、接続開始後に走る非同期処理が利用者所有の可変値を参照しない構造にする。

`Configuration` が struct であることだけに依存せず、内部の参照型、`Any`、`Encodable` を接続開始時に値へ写し取る。mutable handler bag は snapshot に含めず、接続開始時に明示引数として引き渡す。

本 issue は非同期区間の入力源を差し替える refactor である。snapshot 生成時に `dataChannels` の JSON 化可否検証と connect message の JSON encode を行うため、次の 2 つのエラー挙動が変わる。

- JSON 化できない `dataChannels` は、現行のプロセス abort ではなく `SoraError.configurationError` として接続開始前に返る。
- metadata などの encode 失敗は、現行の「握り潰して無送信のままタイムアウト待ち」ではなく `SoraError.configurationError` として接続開始前に返る。

どちらも現行の壊れた挙動の修正であり、正しい入力に対する signaling JSON と WebRTC 設定は変えない。

## 現状

`Sora/Configuration.swift` の `Configuration` は値型だが、次の non-Sendable または可変な値を保持する。

- `signalingConnectMetadata` / `signalingConnectNotifyMetadata` / `audioOpusParams` / `videoVp9Params` / `videoAv1Params` / `videoH264Params` / `videoH265Params` の `Encodable?`
- `dataChannels: Any?`
- `forwardingFilter` / `forwardingFilters` と `ForwardingFilter.metadata: Encodable?`
- `webRTCConfiguration`。`MediaConstraints`、`DegradationPreference`、可変 class の `ICEServerInfo` を含む
- `cameraSettings`。`CameraSettings` は Sendable ではない
- 可変 class の `webSocketChannelHandlers` / `mediaChannelHandlers`
- `audioDevice: RTCAudioDevice?`。利用者が設定する公開 property ではなく、カスタム音声デバイスを注入するテスト用の internal フックである

`MediaChannel.init` は `Configuration` を保存し、handler bag を参照のまま代入する。`SignalingChannel` も `Configuration` を保持し、`webSocketChannelHandlers` を `ws.handlers` へ参照代入する。`PeerChannel` も同じ値を保持する。struct の浅い copy 後も metadata、ICE server、handler の参照は利用者側と共有される。

最初の非同期 hop は `MediaChannel.connect` の `DispatchQueue.global().async` である。この時点で `MediaChannel.init` は `validate`、`NativePeerChannelFactory` の生成、`SignalingChannel` / `PeerChannel` の生成、`ConnectionTimer` の生成を終えている。hop の後では `SignalingChannel` が owner queue 上で、`PeerChannel` が signaling queue と WebRTC スレッドから `configuration` を読む。

競合するのは次の 3 つである。`Configuration` は struct の値渡しのため、利用者が property を再代入しても接続側の copy は変化しない。

- metadata などに渡した reference type のオブジェクトを in-place で変更する場合。encode が非同期区間で行われるため競合する。
- `dataChannels` / `ForwardingFilter.metadata` のように参照型を共有したまま内容を変更する場合。
- `iceServerInfos` の要素である `ICEServerInfo` を in-place で変更する場合。

`SignalingConnect` は `data_channels` の格納プロパティを持たない。`CodingKeys` に `data_channels` はあるが `encode(to:)` からは使われていない。現在の唯一の注入経路は `SignalingChannel.send` が `JSONEncoder` の出力を `JSONSerialization` で `[String: Any]` に戻し、`data_channels` を代入して再シリアライズする処理である。

`PeerChannel.webRTCConfiguration` は `var` で、`configuration.webRTCConfiguration` から初期化された後、offer 受信時に `iceServerInfos` / `iceTransportPolicy` だけがサーバー値で上書きされる。`isInsecure` はサーバー由来ではなく `configuration.insecure` から設定される。

`Sora.connect(webRTCConfiguration:)` の引数は `MediaChannel.connect` を経由して `basicConnect` まで渡されるが、本体で一度も参照されない。実際に使われる WebRTC 設定は `configuration.webRTCConfiguration` だけである。

## 設計方針

### snapshot の型

- 新規ファイル `Sora/ConnectionConfigurationSnapshot.swift` に internal な `struct ConnectionConfigurationSnapshot: Sendable` を置く。`ConnectionLifecycleState` / `SignalingState` と同じく、immutable な値だけを保持する。
- 併せて次の internal 型を本 issue が置く。
  - `struct ICEServerSnapshot: Sendable` (urls / ユーザー名 / credential / TURN-TLS の検証ポリシー)
  - `struct WebRTCConfigurationSnapshot: Sendable` (constraints / `[ICEServerSnapshot]` / ICE transport policy / SDP semantics / degradation preference / insecure)。`MediaConstraints` と `DegradationPreference` は `0123` の完了により `Sendable` に準拠するため、公開型をそのまま保持する
  - `struct ForwardingFilterSnapshot: Sendable` (name / priority / action / rules / version / metadata)。`ForwardingFilterRule` 系も `0123` の完了により `Sendable` に準拠するため、公開型をそのまま保持する
  - `enum JSONValue: Sendable, Equatable` (`null` / `bool` / 符号付き整数 / 符号なし整数 / 浮動小数 / `string` / `array` / `object`。`Encodable` に準拠) を `Sora/JSONValue.swift` に置く
- snapshot のフィールドは `Configuration` の全 stored property を次の 3 つに分類して決める。`spotlightEnabled` は `isSpotlightEnabled` への computed property のため対象は stored property のみである。
  - そのまま値で持つ: `urlCandidates` / `channelId` / `clientId` / `bundleId` / `role` / `multistreamEnabled` / `connectionTimeout` / `videoCodec` / `videoBitRate` / `audioCodec` / `audioBitRate` / `videoEnabled` / `audioEnabled` / `audioStereoOutputEnabled` / `initialCameraEnabled` / `initialMicrophoneEnabled` / `bypassVoiceProcessing` / `isSpotlightEnabled` / `simulcastEnabled` / `simulcastRid` (非推奨だが stored property のため保持) / `simulcastRequestRid` / `spotlightNumber` / `spotlightFocusRid` / `spotlightUnfocusRid` / `dataChannelSignaling` / `ignoreDisconnectWebSocket` / `audioStreamingLanguageCode` / `proxy` / `insecure` / `caCertificate` (PEM 文字列のまま) / publisher の 3 つの ID。派生値の `isMultistream` と `isSender` も接続開始時に確定させる
  - 変換して持つ: `cameraSettings` → `CameraSettingsSnapshot`、`webRTCConfiguration` → `WebRTCConfigurationSnapshot`、`forwardingFilter` / `forwardingFilters` → `ForwardingFilterSnapshot`、metadata / notify metadata / `dataChannels` → `JSONValue?`、codec 一致時のみ codec 別 params → `JSONValue?` (非一致は `nil`)、`requiresStereoAudioSDP` → `Bool`、`usesCustomAudioDevice` → `Bool` (`audioDevice != nil` を接続開始時に確定した派生値)
  - 含めない: `audioDevice`、handler bag
- `multistreamEnabled` は非推奨だが生値のまま snapshot へ凍結する。`SignalingConnect.multistreamEnabled` は `Bool?` で `encodeIfPresent` されるため、`nil` と `true` を区別できないと既定値のときに `"multistream": true` が新規出力されて signaling JSON が変わる。`isMultistream` (`multistreamEnabled ?? true`) は別途確定し、`PeerChannel` の分岐に使う。この読み取りで deprecation 警告が出るが、`0138` は `multistreamEnabled` を対象外としているため、警告の解消は `0138` の対象追加または別 issue とする。
- 非推奨の `spotlightEnabled` は運ばず、確定済みの `isSpotlightEnabled` のみを保持する。
- `isSpotlightEnabled` を Bool で持つ理由は、`Configuration.Spotlight` が public enum で `Sendable` 準拠を持たず、`0123` の対象にも含まれていないためである。`SignalingConnect.spotlightEnabled: Configuration.Spotlight` は変更しないため、`makeSignalingConnect` で Bool から復元する。

### snapshot の生成

- `ConnectionConfigurationSnapshot.init(configuration:) throws` を `Configuration` からの唯一の変換入口とする。テストから単体で生成できるよう、internal な `ICEServerSnapshot.init(_:)` / `WebRTCConfigurationSnapshot.init(_:)` / `ForwardingFilterSnapshot.init(_:)` / `CameraSettingsSnapshot` の変換も用意する。`Encodable` / `Any` から `JSONValue` への変換関数は `Sora/JSONValue.swift` に置く。
- `Sora.connect` は `MediaChannel(configuration:)` の生成より前にこの変換関数を呼び、結果を `MediaChannel` の designated init (`init(snapshot:...)`) へ渡す。`MediaChannel(configuration:)` は通らない。
- `MediaChannel.init(snapshot:configuration:audioDevice:mediaChannelHandlers:webSocketChannelHandlers:...)` を designated init とする。公開互換の `public let configuration` は designated init でしか初期化できないため、snapshot に加えて元の `Configuration` も受け取る。`configuration` は公開 getter 専用とし、接続開始後の非同期処理からは参照しない。
- `MediaChannel.init(configuration:...)` を internal な convenience として残す。convenience は snapshot を生成し、`configuration` から `audioDevice` / `mediaChannelHandlers` / `webSocketChannelHandlers` を取り出して designated init へ渡す。`MediaChannel` を直接生成する既存テストはこの経路を通る。変換の実装は 1 つに固定する。
- `SignalingChannel.init(snapshot:webSocketChannelHandlers:)` とし、`required` は削除する。`insecure` / `urlCandidates` / `proxy` は snapshot から読む。
- `SignalingChannel` / `PeerChannel` は snapshot を必須引数として受け取り、`configuration` プロパティを保持しない。
- `ConnectionConfigurationSnapshot` は internal とする。利用者が actor / Task 境界へ設定値を渡すための公開型は本 issue のスコープ外である。
- 変換に失敗した場合は `SoraError.configurationError(reason:)` を throw する。通知は `Sora.connect` の既存の設定エラー経路を再利用し、`ConnectionTask.complete()` と `DispatchQueue.global().async` で接続 handler と `Sora.handlers.onConnect` を接続スタック外で呼ぶ。`Sora.add(mediaChannel:)`、ADM、WebSocket、`RTCPeerConnection` は生成しない。
- この通知経路は非 `@Sendable` な接続 handler を `DispatchQueue.async` へ capture しており、既存コードにも `#SendableClosureCaptures` の警告がある。本 issue では新しい box を導入せず、警告の除去は別 issue で扱う。
- `MediaChannel.configuration` は公開互換のため利用者が渡した `Configuration` を返し続ける。値型フィールドは `Configuration` と snapshot の両方に同じ値が入るが、接続開始後の非同期処理の読み出し元は snapshot に一本化する。`MediaChannel` 内の残存 `configuration.X` 参照は公開 getter と init の同期区間だけにする。この規則をコメントで明記する。
- `MediaChannel.connect(webRTCConfiguration:)` の internal シグネチャは既存テストの呼び出しを維持するため残すが、`basicConnect` へは渡さない。`basicConnect` の未使用な `webRTCConfiguration` と `timeout` の引数は削除する。`Sora.connect` の公開引数の扱いは `0153` で決める。
- `ConnectionConfigurationSnapshot` に `CustomStringConvertible` は付与しない。`Equatable` も必須としない (`Role` / `Proxy` / `CameraSettings.Resolution` / `SDPSemantics` / `ICETransportPolicy` が `Equatable` ではなく、付与には公開型への conformance 追加が必要になる)。テストは接続 JSON の正規化比較とフィールド単位の検証で行う。
- snapshot 生成は `Sora.connect` の同期区間で行うため、大きな metadata を渡す利用者の `connect` 呼び出しはその分だけブロックする。encode を非同期区間へ遅らせると利用者所有の値を再度読むことになり本 issue の目的に反するため、同期を維持する。
- redirect では snapshot と handler bag を接続開始時のものから作り直さない。`environment` だけが connect message 生成時に再評価される既存挙動を維持する。

### 値の凍結

- 検証は前提 issue が `MediaChannel.validate(configuration:)` に集約し、JSON 化できない `dataChannels` と connect message の encode 失敗を `SoraError.configurationError` として接続開始前に返す。本 issue はその検証器を `ConnectionConfigurationSnapshot.init` から呼び、検証の呼び出し位置を snapshot 生成へ移す。`MediaChannel.validate` に残るのは `audioStereoOutputEnabled` / `audioEnabled` / `audioCodec` / `audioDevice` の組合せ制約だけであり、internal な `validate(snapshot:audioDevice:)` へ置き換える。互換ラッパーは残さない。
- metadata、notify metadata、codec 別 params、`ForwardingFilter.metadata` は snapshot 生成時に `Any` ではなく `Encodable` として `JSONValue` へ encode する。`JSONEncoder` で `Data` にし、`JSONSerialization.jsonObject(with:options:)` に `.fragmentsAllowed` を渡して `Any` に戻してから再帰変換する。これにより利用者が定義した任意の `Encodable` 型と、トップレベルが scalar / array / null の値も現行どおり受け付ける。
- `dataChannels: Any?` は別経路とし、Foundation の型 (`NSNull` / `Bool` / 整数 / 浮動小数 / `String` / `配列` / `辞書`) を再帰的に検査して `JSONValue` へ変換する。JSON 化できない型は `SoraError.configurationError` として接続開始前に返す。数値は bool / 符号付き整数 / 符号なし整数 / 浮動小数を区別し、`Int64` / `UInt64` の精度を失わない。`NSNumber` の bool 判定は `CFBooleanGetTypeID` で行い、整数と浮動小数は `CFNumberIsFloatType` で分ける。
- `Decimal` / `Float` は `JSONEncoder` の出力を経由するため現行と同じ表現になる。`NaN` / `Infinity` は `JSONEncoder` が `invalidValue` を throw するため、snapshot 生成時に `SoraError.configurationError` として返る (現行の握り潰しからの変更点の 1 つ)。
- `metadata` は `nil` と `Optional.some(NSNull())` を区別する。前者は `metadata` キーを出力せず、後者は `null` を出力する (現行の `if let metadata` と同じ)。
- `JSONValue` は `SignalingConnect` の `Encodable?` プロパティ (`metadata` / `notifyMetadata` / `opusParams` / `vp9Params` / `av1Params` / `h264Params` / `h265Params`) へそのまま渡せる。`SignalingConnect` の `encode(to:)` は `superEncoder` 経由で値の `encode(to:)` を呼ぶため、公開プロパティ型と `makeSignalingConnect` のシグネチャを変更せずに事前 encode 済みの値を注入できる。
- 事前 encode した `Data` を保持する案は採らない。`superEncoder` へ `Data` を渡すと base64 文字列になり signaling JSON が壊れるためである。この理由をコードコメントに残す。
- codec 別 params は既存と同じ codec 一致条件で保持する。`videoCodec == .vp9` のときだけ vp9 params を、`audioCodec == .opus` のときだけ opus params を `JSONValue` 化し、他は `nil` とする。条件の意味は維持し、参照元だけを snapshot へ置き換える。
- metadata が `nil` のときに `"metadata": {}` を送らない条件と、`ForwardingFilter.metadata` の nil 条件を維持する。
- `dataChannels` は `JSONValue?` として `dataChannelSettings` に保持する。名前は `PeerChannel.dataChannels: [String: DataChannel]` と `SignalingOffer.dataChannels` と区別するため `dataChannelSettings` とする。internal な `SignalingConnect.dataChannelSettings` へ `PeerChannel.makeSignalingConnect` で渡す。`SignalingChannel.send` の `JSONSerialization` によるマージは削除する。
- `ForwardingFilterSnapshot` から `SignalingConnect.forwardingFilter` / `forwardingFilters` へ戻す再変換を実装する。`SignalingConnect` のこれらは `ForwardingFilter` / `[ForwardingFilter]` 型であり `Encodable?` ではないため、`JSONValue` をそのまま渡せない。再変換では `metadata` を `JSONValue` (Encodable) として渡し、`ForwardingFilter.encode(to:)` の metadata nil 抑止と同じ出力になることをテストで固定する。
- `ICEServerSnapshot` に `CustomStringConvertible` を付与せず、`credential` / `username` を含む値の新しい文字列化経路を追加しない。既存の `ICEServerInfo.description`、`Logger.maskSecrets` の対象キー、`urlCandidates` のログに残る漏えいは `0156` で扱う。
- `ICEServerSnapshot` は URL、ユーザー名、credential、TURN-TLS の検証ポリシーを copy する。`0030` 完了後は格納プロパティ `username` を読む。検証ポリシーは、`0138` が導入する internal な真値 (検証を行うか否かを表す Bool) の名前と意味に合わせて `ICEServerSnapshot` の Bool として保持し、非推奨の `userName` / `tlsSecurityPolicy` を新規に参照しない。`RTCTlsCertPolicy` への写像と `usesVerifiedTURNTLS` の判定は snapshot 側の computed property に一本化し、`insecure` を優先する既存の関係を再現する。
- `parsedCACertificates()` は現在 `extension Configuration` のメソッドであり、`configuration` を保持しない `SignalingChannel` / `PeerChannel` からは呼べない。PEM 文字列を受け取る自由関数または snapshot のメソッドへ移し、呼び出し元をそこへ切り替える。`Configuration.parsedCACertificates()` はテスト互換のため現状のまま残す。パース位置の一本化は本 issue では行わない。
- `CameraSettings` は既存の `CameraSettingsSnapshot` を再利用し、`isEnabled` を追加して拡張する。`PeerChannel` が接続中に読む `cameraSettings.isEnabled` / `.position` / `.resolution` / `.frameRate` を snapshot へ置き換える。既存の `CameraSettingsSnapshot` 利用箇所は `init(_ cameraSettings:)` 経由のため影響しない。
- `audioDevice` は snapshot に含めない。`RTCAudioDevice` が必要な `NativePeerChannelFactory` の生成は `MediaChannel.init` の同期区間で行う。`PeerChannel` の接続処理が snapshot から必要とするのは `requiresStereoAudioSDP` (SDP 用) と `usesCustomAudioDevice` (`audioDevice != nil` を接続開始時に確定した派生値) の 2 つである。`PeerChannel.initializeSenderStream` の `configuration.audioDevice` 参照は `usesCustomAudioDevice` で置き換える。`requiresStereoAudioSDP` で代用してはならない。`requiresStereoAudioSDP` は `audioStereoOutputEnabled || audioDevice?.outputNumberOfChannels == 2` であり `audioDevice != nil` と等価ではなく、代用するとネイティブ ADM のステレオ接続でマイク入力が初期化されず、モノラルのカスタムデバイスで逆に初期化される退行になる。
- `MediaChannel.init` の同期区間で使う `audioStereoOutputEnabled` / `isSender` / `bypassVoiceProcessing` / `connectionTimeout` は snapshot から読む。`AudioSessionUsage` の算出と `ConnectionTimer` の生成も snapshot を用いる。`audioDevice` と handler bag だけは snapshot ではなく init の引数で受け取る。
- `DeviceInfo.current` は利用者由来の設定ではないため snapshot に含めない。`environment` は既存どおり connect message 生成時に読み、redirect 再送時も再評価される既存挙動を維持する。読み取りの安全化は `0112` で扱う。

### handler bag の引き渡し

- mutable handler bag を `ConnectionConfigurationSnapshot` に含めない。非 `@Sendable` な closure を保持する型は checked `Sendable` に準拠できないためであり、完了条件の「deep Sendable」は `ConnectionConfigurationSnapshot` のみを指す。
- `MediaChannel.init` は `mediaChannelHandlers` を、`SignalingChannel.init` は `webSocketChannelHandlers` を明示引数として受け取る。`SignalingChannel` から `configuration` を削除するため、`ws.handlers` への代入元を引数へ移す必要がある。
- 引き渡すのは handler bag の参照であり、closure を copy しない。配送のたびに bag を読む既存挙動を維持し、接続開始後の handler 変更が次の配送から反映されることを保証する。`skills/sora-ios-sdk/SKILL.md` の接続フロー (接続成功後に `MediaChannel.handlers` でコールバックを登録する手順) と、接続後に `MediaChannel.handlers` を設定する既存テストを壊さない。
- `MediaChannel.internalHandlers` / `PeerChannel.internalHandlers` / `SignalingChannelInternalHandlers` は接続開始前に 1 回だけ設定し、以降に書き換える経路が無いため排他も copy もしない。この前提を崩す変更を入れる場合は排他を追加する。
- closure property の読み書きの排他は本 issue では行わない。本 issue の完了後に別 issue を起票して扱う (`0110` の event API と `0111` の `SoraHandlers` 同期の対象ではない)。

### offer 由来で更新される設定

- `Configuration.webRTCConfiguration` の全フィールド (constraints / `[ICEServerSnapshot]` / ICE transport policy / SDP semantics / degradation preference / insecure) を利用者由来の snapshot に含める。
- `PeerChannel` は同じ `WebRTCConfigurationSnapshot` 型の接続所有インスタンスを別に持ち、offer 受信時に `iceServerInfos` と `iceTransportPolicy` だけをサーバー値で上書きする。`isInsecure` は offer ではなく `Configuration.insecure` から設定する。利用者由来 snapshot の `isInsecure` は `Configuration.insecure` を写すが、接続所有インスタンスは `isInsecure == false` で生成し、offer 受信時に `Configuration.insecure` を設定する。一時 offer 生成では `isInsecure` が false である既存挙動を維持する。既存の更新経路とフェーズ依存の意味 (一時 offer 生成では利用者値、本 `RTCPeerConnection` 生成ではサーバー値) を変えない。
- 接続所有インスタンスは `PeerChannel` に追加する専用の `NSLock` (`webRTCConfigurationLock`) 配下でのみ読み書きする。既存の `PeerChannel.lock` は非同期処理数のカウンタであり排他を提供しないため使用しない。lock は offer 更新区間と `initializeSenderStream` / `createAnswer` / `createClientOfferSDP` の読み取り区間だけで保持し、libwebrtc の非同期 callback や `await` をまたいで保持しない。
- 接続所有インスタンスは生成時に利用者 snapshot の `WebRTCConfigurationSnapshot` を値コピーして初期化する。`offer.configuration` が `nil` の場合は利用者値のまま本 `RTCPeerConnection` を生成し、`offer.configuration` がある場合だけ `iceServerInfos` / `iceTransportPolicy` を差し替える。`isInsecure` は offer ではなく `Configuration.insecure` から無条件に設定する (提供元が違うため同じ更新経路にまとめない)。
- `PeerChannel.webRTCConfiguration` は `WebRTCConfigurationSnapshot` 型へ置き換え、`createClientOfferSDP` / `createNativePeerChannel` / `setConfiguration` と constraints の全参照を移行する。旧 `WebRTCConfiguration` 型のプロパティは残さない。
- `ConnectionConfigurationSnapshot` に `nativeValue` (`RTCConfiguration`) と `nativeConstraints` (`RTCMediaConstraints`) を持たせ、`NativePeerChannelFactory` の `createNativePeerChannel` / `createCertificateVerifier` / `createClientOfferSDP` と、`PeerChannel` の `setConfiguration` / `createAnswer` の constraints をここから供給する。`WebRTCConfigurationSnapshot.init(_ configuration: WebRTCConfiguration)` を定義し、既存テストが `WebRTCConfiguration` から直接生成できるようにする。`createNativeSenderStream` は `MediaConstraints` のみを受け取るため、snapshot 側の `MediaConstraintsSnapshot` から組み立てる経路へ置き換える。`usesVerifiedTURNTLS` は接続所有インスタンス (`isInsecure` + `[ICEServerSnapshot]`) から判定し、一時 offer 用の `createClientOfferSDP` は凍結 snapshot の利用者値から判定する。AES-GCM を有効にする `cryptoOptions` の組み立ては `nativeValue` に含める。

### 互換性

- 公開 `Configuration` の property と initializer を維持する。
- `Configuration: Sendable` または `@unchecked Sendable` は付与しない (struct の浅い copy では参照先を凍結できないため)。
- `SignalingConnect` の公開プロパティ型と `PeerChannel.makeSignalingConnect` のシグネチャを変更しない。internal な `SignalingConnect.dataChannelSettings` を追加し、`default` 値を持たせて既存の memberwise init 呼び出しを変えない。
- `MediaChannel.configuration` は元 `Configuration` を返し続ける。そのため `MediaChannel` は Sendable ではなく、利用者が `configuration` を actor / Task 境界へ渡す要件は `0152` で扱う。`Sora.connect` の公開シグネチャは変えない。`MediaChannel.validate` は internal のため、snapshot と `audioDevice` を受け取る形へ変更する。
- `CHANGES.md` の `## develop` に、refactor 部分を `### misc` の `[UPDATE]` として、次の 2 つの挙動修正を `[FIX]` として追記する。JSON 化できない `dataChannels` でプロセスが abort する問題と、connect message の encode 失敗を握り潰して接続タイムアウトまで待たせる問題。種別の順序 (UPDATE → FIX) と担当者行の書式は `shiguredo-changelog` に従う。
- `0107` の API baseline は未整備のため、本 issue では `git diff` と目視で公開 API 差分ゼロを確認する。`dataChannelSettings` は internal のため差分に出ない。baseline による機械検査は `0107` の完了後に行う。

## スコープ外

- `0110` (Sendable event API と executor 契約) で扱う、handler の `@Sendable` 化。
- `0111` (Sora の共有状態) で扱う、`SoraHandlers` の同期。
- `0154` で扱う、`MediaChannelHandlers` / `WebSocketChannelHandlers` の closure property の読み書きの排他。
- 本 issue の完了後に別 issue を起票して扱う、connect message の JSON 化で残る範囲 (encode 失敗の通知メッセージの詳細化など)。
- `0152` で扱う、利用者が actor / Task 境界へ設定値を渡せる公開 Sendable 設定型の追加。
- `0153` で扱う、`Sora.connect(webRTCConfiguration:)` の引数が接続に反映されない不具合。
- `0155` で扱う、`Sora.connect` の設定エラー通知経路にある non-`@Sendable` closure capture の警告除去。
- `ICEServerInfo` を公開 struct に変更する破壊的 API 変更。
- `0156` で扱う、ログと文字列表現からのシークレット漏えいの防止 (`Logger.maskSecrets` の対象キー、`ICEServerInfo.description`、`urlCandidates` のログ、マスクの単体テスト)。
- `PeerChannel.lock` の役割と `PeerChannel` 全体の排他設計は `0129` (PeerChannel.Lock の統合) で扱う。本 issue は接続所有 WebRTC 設定の読み書きに専用 lock を追加するところまでとする。
- `MediaConstraints` / `DegradationPreference` / `ForwardingFilterRule` / `ForwardingFilterRuleField` / `ForwardingFilterRuleOperator` / `ForwardingFilterAction` への `Sendable` 準拠の追加は `0123` が先行して行う。本 issue はこれらの公開型をそのまま snapshot に保持し、mirror 型を作らない。

## 変更対象

- `Sora/JSONValue.swift` (新規): `JSONValue` 型と `Encodable` / `Any` からの変換
- `Sora/ConnectionConfigurationSnapshot.swift` (新規): snapshot 型、`ICEServerSnapshot`、`WebRTCConfigurationSnapshot`、`ForwardingFilterSnapshot`、変換処理
- `Sora/Configuration.swift`: `parsedCACertificates()` の実装を snapshot 側へ移し、既存テスト互換の薄いラッパーを残す
- `Sora/Sora.swift`: snapshot 生成と呼び出し順序 (設定エラー経路の呼び出しは変更するが box 化はしない)
- `Sora/MediaChannel.swift`: designated init の変更、`configuration` 参照の置き換え、`validate(snapshot:audioDevice:)` への変更
- `Sora/PeerChannel.swift`: snapshot の受け取り、接続所有の WebRTC 設定の分離、`configuration` 参照の置き換え、`webRTCConfigurationLock` の追加
- `Sora/SignalingChannel.swift`: snapshot と handler bag の受け取り、`configuration` 参照の置き換え
- `Sora/Signaling.swift`: internal な `SignalingConnect.dataChannelSettings` の追加 (`default` 付きで既存の memberwise init 呼び出しを変えない)、`data_channels` の encode、`SignalingChannel.send` の `JSONSerialization` マージの削除
- `Sora/WebRTCConfiguration.swift` / `Sora/NativePeerChannelFactory.swift`: snapshot から `RTCConfiguration` を組み立てる経路
- `Sora/VideoMute.swift`: `CameraSettingsSnapshot` への `isEnabled` 追加
- `SoraTests/ConfigurationTests.swift`: CA 解析の呼び出し先の移行と snapshot 変換の単体テスト
- `SoraTests/ConnectionConfigurationSnapshotTests.swift` (新規): 不変性、deep Sendable、connect JSON のゴールデン比較
- `SoraTests/PeerChannelConnectEncodingTests.swift` / `SignalingConnectTests.swift` / `PeerChannelConnectCompletionTests.swift` / `PeerChannelRedirectInvalidationTests.swift` / `ConnectionTaskTests.swift` / `ConnectionTimerLifecycleTests.swift`: `try ConnectionConfigurationSnapshot(configuration:)` を追加し、`SignalingChannel(snapshot:webSocketChannelHandlers:)` / `PeerChannel(snapshot:...)` へ置換する。`ConnectionTimerLifecycleTests` の `makeSignalingChannel()` は非 throwing のため、ヘルパーとその呼び出し元を `throws` 化する。
- `SoraTests/DummyAudioDeviceTests.swift` / `SoraTests/StereoAudioOutputTests.swift`: `MediaChannel.validate(snapshot:audioDevice:)` への呼び出しの移行と、`NativePeerChannelFactory` の呼び出しの移行
- `CHANGES.md`

## 前提となる issue

- `0100` (完了 2026-09-08): `ConnectionStateOwner` / `ConnectionSnapshotStorage` / 純粋 reducer。同じ配置・命名の考え方に揃える。
- `0101` (完了 2026-09-15): `SignalingState` / `SignalingStateOwner`。`SignalingChannel` の `configuration` 参照を snapshot へ置き換える土台になる。
- `0138` (非推奨 API の内部利用除去) と `0030` (`ICEServerInfo` の userName): 先に完了させ、`ICEServerInfo` の内部表現を確定させる。完了前に着手する場合は現行の `userName` / `tlsSecurityPolicy` を読み、変換関数 1 箇所に非推奨警告が残ることを許容する。
- `0123`: `MediaConstraints` / `DegradationPreference` / `ForwardingFilterRule` 系への `Sendable` 準拠の追加。本 issue が snapshot に公開型をそのまま保持するために先行を必須とする。`0123` の検証が `0107` の consumer fixture に依存している場合は、`SoraTests` の `requireSendable` によるコンパイル時表明で代替して先に完了させる。
- `0107`: consumer fixture と API baseline (未完了)。本 issue では公開 API 差分ゼロを `git diff` と目視で確認し、`0107` 完了後の baseline 検査に委ねる。
- `0025` (`SignalingChannelInternalHandlers.onSend` の削除): 先に完了していることが望ましいが、必須ではない。`0025` は `SignalingChannel.send` の 1 行 (`onSend` の適用) を削除するだけで、本 issue が変える `data_channels` のマージとは行が重ならず、意味的な依存も無い (`onSend` はどこからも設定されていないデッドコードである)。同時に進める場合は `SignalingChannel.send` の近接行を触るため rebase する。

### 順序調整

- `0141` (SignalingChannel の責務純化) は `SignalingChannel.send` / `handle` の JSON codec 分離で同じメソッドを書き換えるため、本 issue の完了後に着手する。

### 本 issue を前提とする

- `0109` (`0109` が「`Configuration` 内の metadata / `Any` は `0102` で扱う」と委譲している)
- `0110` (`0110` が mutable handler bag と設定 snapshot の分離を本 issue の担当としている)
- `0026`: `PeerChannel.connect` の `WrapperVideoEncoderFactory.shared.simulcastEnabled` 設定行を本 issue も変更するため、本 issue を先に完了させる (`0026` は接続設定の snapshot を自スコープ外としている)。

### 並行して進められる issue

- `0156`: ログと文字列表現からシークレットが漏れないようにする。

### 本 issue の完了後に着手する issue

- `0152`: 利用者が actor / Task 境界へ渡せる公開 Sendable 設定型を追加する
- `0153`: `Sora.connect(webRTCConfiguration:)` に渡した設定が無視される問題を修正する
- `0154`: MediaChannel と WebSocketChannel の handler bag の読み書きを排他する
- `0155`: `Sora.connect` の設定エラー通知経路の non-`@Sendable` closure capture を解消する

## テスト方針

モックやスタブは使用しない。

- 実 `Configuration` から snapshot を生成し、元の metadata object、`ForwardingFilter.metadata`、`ICEServerInfo` を変更しても snapshot と送信 JSON が変化しないことを確認する。
- value type の property 再代入は元々接続側へ伝播しないことと、reference type の in-place 変更だけが凍結対象であることを日本語コメントで明記する。
- 前提 issue の `JSONValue` へ変換した値が、snapshot 経由で `SignalingConnect` に渡ったときに元の `Encodable` / `Any` と同一の JSON になることを検証する。変換単体の網羅テストは前提 issue が持つ。
- `ConnectionConfigurationSnapshot` が `Sendable` であることをコンパイル時に検証する。internal 型のため `SoraTests` 内の nonisolated actor / Task 境界へ渡す compile scenario で行い、`0107` の consumer fixture は public API のみを対象とする。
- codec 別 params が codec 一致時のみ `SignalingConnect` へ渡ることを検証する。opus 側の同条件は既存 `SignalingConnectTests` が担保しているため、`videoCodec != .vp9` で vp9 params が送られないことを追加で検証する。
- metadata が `nil` のとき `"metadata"` キーが出力されず、`ForwardingFilter.metadata` が `nil` のとき空 object が出力されないことを検証する。
- `metadata` が `nil` / `Optional.some(NSNull())` / scalar / 空 object の各場合で、出力が現行と同じ (`null` とキー省略を区別する) であることを検証する。
- `NaN` / `Infinity` を含む metadata が `SoraError.configurationError` になり、プロセスが abort しないことを検証する。
- ゴールデン JSON は `Configuration` のフィクスチャごとに `SoraTests/ConnectionConfigurationSnapshotTests.swift` に固定し、`Configuration` にフィールドを追加したときは同ファイルの期待値を更新する。
- `CameraSettingsSnapshot` の `isEnabled` が snapshot に反映されることを検証する。
- `ICEServerSnapshot` が TURN-TLS の検証ポリシーを保持し、`usesVerifiedTURNTLS` の判定が変わらないことを検証する。
- `ConnectionConfigurationSnapshot` の生成前に、対象の `Configuration` ごとの connect JSON をゴールデン文字列として `SoraTests/ConnectionConfigurationSnapshotTests.swift` に固定する。変更後は snapshot 経路で生成した connect JSON を正規化して比較する。キー順の差異は比較対象にしない。比較は `PeerChannel.makeSignalingConnect` を直接呼び、`Signaling.connect` を `JSONEncoder` で encode する同期テストで行う。実 Sora 接続は signaling が成立しサーバーが accept することの確認に役割を限定する。
- `SendonlyE2ETests` の `data_channels` 検証と `ConfigurationTests` の CA 解析検証を回帰検証として使う。
- 接続開始後に `MediaChannel.handlers` を変更した場合、次の配送から反映される既存挙動が維持されることを確認する。`E2ETestBase` の `disconnectAndVerify` / `disconnectAll` が無修正で成功することを回帰条件とする。
- `Sora` と `SoraTests` を `SWIFT_VERSION=6` と `SWIFT_STRICT_CONCURRENCY=complete` でビルドし、変更前後で `#SendableClosureCaptures` などの concurrency 診断の件数を数えて増えていないことを差分で示す。現行 CI に `SWIFT_STRICT_CONCURRENCY` のゲートは無いため、ローカルの `xcodebuild` 実行結果を残す。test target の gate の本対応は `0118` が扱う。
- Thread Sanitizer が利用できる場合は、接続中に元の metadata object と `ICEServerInfo` を別スレッドから変更し、race report が出ないことを確認する。`0119` の CI 基盤が未整備の間は `-enable-thread-sanitizer` を付けた手動実行の結果を残す。
- 既存テストと追加テストがすべて成功することを確認する。

## 完了条件

- `ConnectionConfigurationSnapshot` が immutable かつ deep Sendable であること (handler bag を含まない)。
- snapshot 生成に失敗した場合、ADM、WebSocket、`RTCPeerConnection` を生成する前に `SoraError.configurationError` として終端すること。
- metadata、notify metadata、codec parameter、`forwardingFilter` / `forwardingFilters` の metadata、`dataChannels` が snapshot 生成時に `JSONValue` へ写されること。
- `ICEServerInfo` が参照共有されない internal value type へ copy され、TURN-TLS の検証ポリシーが維持されること。
- snapshot が raw WebRTC / Objective-C object (`RTCAudioDevice`) を保持しないこと。
- `requiresStereoAudioSDP` / `usesCustomAudioDevice` とカメラ設定 (`isEnabled` を含む) の判定材料が接続開始時に確定していること。
- `ConnectionConfigurationSnapshot` / `ICEServerSnapshot` / `WebRTCConfigurationSnapshot` / `ForwardingFilterSnapshot` が checked `Sendable` に準拠していること。`@unchecked Sendable` を付与していないこと。
- `WebRTCConfigurationSnapshot` と `ForwardingFilterSnapshot` が `MediaConstraints` / `DegradationPreference` / `ForwardingFilterRule` 系の公開型をそのまま保持し、mirror 型を定義していないこと。
- 接続開始後の非同期処理が `Configuration` の参照型フィールド (metadata / notify metadata / `dataChannels` / `forwardingFilter` / `forwardingFilters` / `webRTCConfiguration`) を参照せず、snapshot を参照していること。`MediaChannel.configuration` の公開 getter と `MediaChannel.init` の同期区間は除く。
- internal な `SignalingConnect.dataChannelSettings` へ snapshot の `dataChannelSettings` を渡していること。
- `MediaChannel.validate(snapshot:audioDevice:)` が audio の組合せ制約のみを持ち、`configuration` を受け取らないこと。
- handler bag が `ConnectionConfigurationSnapshot` から分離され、明示引数として `MediaChannel` / `SignalingChannel` へ引き渡されること。
- 接続開始後に handler を変更した場合の配送が既存挙動を維持すること。
- 公開 `Configuration` に `@unchecked Sendable` を付与していないこと。
- 公開 API のシグネチャが変更されていないこと。
- signaling message と WebRTC 設定の既存挙動が維持されること。
- `CHANGES.md` の `## develop` に、refactor を `### misc` の `[UPDATE]` として、JSON 化できない `dataChannels` による abort の解消と encode 失敗の握り潰しの解消を `[FIX]` として追記していること。
- `Sora` と `SoraTests` が `SWIFT_VERSION=6` と `SWIFT_STRICT_CONCURRENCY=complete` でビルドでき、変更前後で concurrency 診断の件数が増えていないこと。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
