# 接続設定を immutable な Sendable snapshot へ変換する

- Created: 2026-08-27
- Completed: 2026-09-16
- Priority: Medium
- Branch: feature/refactor-configuration-snapshot
- Polished: 2026-09-15

## 目的

接続開始時に利用者の `Configuration` を immutable かつ deep Sendable な内部 snapshot へ変換し、接続開始後に走る非同期処理が利用者所有の可変値を参照しない構造にする。

`Configuration` が struct であることだけに依存せず、内部の参照型、`Any`、`Encodable` を接続開始時に値へ写し取る。mutable handler bag は snapshot に含めず、接続開始時に明示引数として引き渡す。

本 issue は非同期区間の入力源を差し替える refactor であり、signaling JSON と WebRTC 設定の値と解釈を変えない (数値の表記と、`dataChannels` が非 nil のときの connect message に載る `Decimal` の値だけは次の段落の例外がある)。JSON 化できない `dataChannels` と connect message に載る metadata などの encode 失敗を `SoraError.configurationError` として接続開始前に返す検証は、前提 issue の `0158` が追加する。本 issue はその検証を snapshot 生成へ移設して 1 箇所に保つ (検証の条件も失敗時の挙動も変えない)。

唯一の例外は数値である。変換経路が変わるため `Float` / `Double` の表記 (指数表記の展開、`-0.0` の符号) が変わり得るが値は同一である。また `dataChannels` が非 nil のとき connect message に載る `Decimal` は現行が壊れており (実測: `1.0000000000000001` が `1`)、変更後は利用者入力どおりになる (詳細は「値の凍結」を参照)。

`Decimal` の値の修正を本 issue に含めるのは、原因が `SignalingChannel.send` の `JSONSerialization` 再直列化そのものであり、本 issue が `data_channels` を `SignalingConnect.encode(to:)` へ移してこの処理を削除するためである。`Any` を再直列化せずに connect JSON へ載せる手段は `JSONValue` と internal な `SignalingConnect.dataChannelSettings` しかなく、別 issue に切り出しても同じ行に対して本 issue の部分集合を実装することになる。元からあるバグがこの機構の廃止に伴って直るため、`CHANGES.md` の `[FIX]` として記録する。

## 現状

`Sora/Configuration.swift` の `Configuration` は値型だが、次の non-Sendable または可変な値を保持する。

- `signalingConnectMetadata` / `signalingConnectNotifyMetadata` / `audioOpusParams` / `videoVp9Params` / `videoAv1Params` / `videoH264Params` / `videoH265Params` の `Encodable?`
- `dataChannels: Any?`
- `forwardingFilter` / `forwardingFilters` と `ForwardingFilter.metadata: Encodable?`
- `webRTCConfiguration`。`MediaConstraints` と `DegradationPreference` は `0123` の完了により `Sendable` で、可変 class の `ICEServerInfo` が残る
- 可変 class の `webSocketChannelHandlers` / `mediaChannelHandlers`
- `audioDevice: RTCAudioDevice?`。利用者が設定する公開 property ではなく、カスタム音声デバイスを注入するテスト用の internal フックである

`MediaChannel.init` は `Configuration` を保存し、handler bag を参照のまま代入する。`SignalingChannel` も `Configuration` を保持し、`webSocketChannelHandlers` を `ws.handlers` へ参照代入する。`PeerChannel` も同じ値を保持する。struct の浅い copy 後も metadata、ICE server、handler の参照は利用者側と共有される。

最初の非同期 hop は `MediaChannel.connect` の `DispatchQueue.global().async` である。この時点で `MediaChannel.init` は `validate`、`NativePeerChannelFactory` の生成、`SignalingChannel` / `PeerChannel` の生成、`ConnectionTimer` の生成を終えている。hop の後では `SignalingChannel` が owner queue 上で、`PeerChannel` が signaling queue と WebRTC スレッドから `configuration` を読む。

競合するのは次の 3 つである。`Configuration` は struct の値渡しのため、利用者が property を再代入しても接続側の copy は変化しない。

- metadata などに渡した reference type のオブジェクトを in-place で変更する場合。encode が非同期区間で行われるため競合する。
- `dataChannels` / `ForwardingFilter.metadata` のように参照型を共有したまま内容を変更する場合。
- `iceServerInfos` の要素である `ICEServerInfo` を in-place で変更する場合。

`SignalingConnect` は `data_channels` の格納プロパティを持たない。`CodingKeys` に `data_channels` はあるが `encode(to:)` からは使われていない。現在の唯一の注入経路は `SignalingChannel.send` が `JSONEncoder` の出力を `JSONSerialization` で `[String: Any]` に戻し、`data_channels` を代入して再シリアライズする処理である。この再直列化は connect message 全体に掛かるため、`dataChannels` が非 nil のときは connect message に載る `Double` / `Float` が 17 桁表記になり、`JSONSerialization` が `Decimal` を `NSNumber` (Double) へ落とすため Double の精度で表現できない `Decimal` は値が壊れる (実測: `1.0000000000000001` が `1`)。

`PeerChannel.webRTCConfiguration` は `var` で、`configuration.webRTCConfiguration` から初期化された後、offer 受信時に `iceServerInfos` / `iceTransportPolicy` だけがサーバー値で上書きされる。`isInsecure` はサーバー由来ではなく `configuration.insecure` から設定される。

`Sora.connect(webRTCConfiguration:)` の引数は `MediaChannel.connect` を経由して `basicConnect` まで渡されるが、本体で一度も参照されない。実際に使われる WebRTC 設定は `configuration.webRTCConfiguration` だけである。

### 再現手順 (metadata の `Decimal` が壊れる問題)

1. `Configuration` の `signalingConnectMetadata` に `Decimal(string: "1.0000000000000001")` を含む `Encodable` を設定する。
2. `dataChannels` に JSON 化できる辞書 (`["x": 1]`) を設定する (非 nil であることが条件)。
3. `Sora.connect` で接続する。

期待: metadata に `1.0000000000000001` が送られる。実際: `SignalingChannel.send` が connect message 全体を `JSONSerialization` で再直列化するため `1` が送られる (実測)。`dataChannels` が nil のときは `1.0000000000000001` のまま送られる。

## 設計方針

### snapshot の型

- 新規ファイル `Sora/ConnectionConfigurationSnapshot.swift` に internal な `struct ConnectionConfigurationSnapshot: Sendable` を置く。stored property はすべて `let` とする。`Sendable` が値型へ要求するのは immutability ではなく保持する値の再帰的な `Sendable` 性であるため、完了条件を機械的に確認できるよう `let` を明示する。
- 値型の名前は、`0100` / `0101` の `ConnectionLifecycleState` / `SignalingState` が接続の段階を表すのに対し、本 issue の型は `Configuration` の値の写しであるため `...Snapshot` とする。
- 併せて次の internal 型を本 issue が置く。
  - `struct ICEServerSnapshot: Sendable` (urls / username / credential / TURN-TLS のポリシー)。ポリシーは internal な `isTLSInsecure: Bool` (`tlsSecurityPolicy == .insecure` の真値) として保持し、`nativeValue(insecure:)` と `usesVerifiedTURNTLS` を computed property として提供する。`init(_ info: ICEServerInfo)` と、接続所有インスタンスを組み直すための internal な memberwise 相当の init を用意する (stored property がすべて `let` のため、offer 受信時の差し替えはこの init で新しい値を作る)。`nativeValue(insecure:)` の `tlsCertPolicy` は `insecure || isTLSInsecure` のとき `.insecureNoCheck`、それ以外は `.secure` とする。`usesVerifiedTURNTLS` は `!isTLSInsecure && urls.contains { $0.lowercased().hasPrefix("turns:") }` とする (現行の `ICEServerInfo.usesVerifiedTURNTLS` と同じ判定)。`WebRTCConfigurationSnapshot.usesVerifiedTURNTLS` は `!isInsecure && iceServers.contains { $0.usesVerifiedTURNTLS }` とする (現行の `WebRTCConfiguration.usesVerifiedTURNTLS` と同じ判定)。これは現行の `ICEServerInfo.nativeValue(insecure:)` / `ICEServerInfo.usesVerifiedTURNTLS` の実装を移設したもので、移設後に `ICEServerInfo` 側の 2 つは未参照になるため削除する (「変更対象」を参照)。`isTLSInsecure` は `0138` (`ICEServerInfo` の非推奨 `tlsSecurityPolicy` を internal な真値へ置き換える) と同じ意味で持ち、`0138` の完了後はその真値を copy する (`0138` の完了時に確定した識別子を使う)。
  - `struct WebRTCConfigurationSnapshot: Sendable` (constraints / `[ICEServerSnapshot]` / ICE transport policy / SDP semantics / degradation preference / isInsecure)。`MediaConstraints` と `DegradationPreference` は `0123` の完了により `Sendable` のため公開型をそのまま保持し、mirror 型を作らない。`init(_ configuration: WebRTCConfiguration)` (`isInsecure` は元の値を写す) と、offer 受信時の差し替え用に `init(constraints:iceServerInfos:iceTransportPolicy:sdpSemantics:degradationPreference:isInsecure:)` を用意する。
    - `WebRTCConfiguration` の internal な `nativeValue: RTCConfiguration` と `nativeConstraints: RTCMediaConstraints` の実装をこの型の computed property へ移設する。computed property とするのは `RTCConfiguration` / `RTCMediaConstraints` が WebRTC の Objective-C class で `Sendable` ではなく、stored property にすると checked `Sendable` が成立しないためである。
    - `usesVerifiedTURNTLS` もこの型の computed property へ移設する。
    - 移設後、`WebRTCConfiguration` 側の同名メンバは削除する。同じ実装を 2 箇所に残さない。
  - `struct ForwardingFilterSnapshot: Sendable` (name / priority / action / rules / version / metadata)。`ForwardingFilterRule` 系も `0123` の完了により `Sendable` のため公開型をそのまま保持し、mirror 型を作らない。metadata の encode を行うため `init(_ forwardFilter: ForwardingFilter) throws` とする。
  - `enum JSONValue: Sendable, Equatable` を `Sora/JSONValue.swift` に置く。ケースは `case null` / `case bool(Bool)` / `case int(Int64)` / `case uint(UInt64)` / `case decimal(Decimal)` / `case double(Double)` / `case string(String)` / `case array([JSONValue])` / `case object([String: JSONValue])` とし、`Encodable` / `Decodable` に準拠する。`Encodable` は `singleValueContainer` へ書き、親の `superEncoder` 経由で入れ子のコンテナを作らない (二重コンテナを作ると `"metadata": {"metadata": ...}` になる)。`Decodable` の `init(from:)` は `let c = try decoder.singleValueContainer()` → `c.decodeNil()` なら `.null` → `try? c.decode(Bool.self)` → `try? c.decode(Decimal.self)` → `try? c.decode(Double.self)` → `try? c.decode(Int64.self)` → `try? c.decode(UInt64.self)` → `try? c.decode(String.self)` → `try? c.decode([JSONValue].self)` → `try? c.decode([String: JSONValue].self)` の順に試し、すべて失敗したら `DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: ...))` を throw する。本 issue では internal とする。公開型としての `JSONValue` が必要な場合は `0157` が public 化する (本 issue は公開 API を増やさない)。
- snapshot のフィールドは `Configuration` の全 stored property を次の 3 つに分類して決める。非推奨の `spotlightEnabled` は `isSpotlightEnabled` を読み書きする computed property のため、stored property である `isSpotlightEnabled` だけを対象にする。
  - そのまま値で持つ: `urlCandidates` / `channelId` / `clientId` / `bundleId` / `role` / `multistreamEnabled` / `connectionTimeout` / `videoCodec` / `videoBitRate` / `audioCodec` / `audioBitRate` / `videoEnabled` / `audioEnabled` / `audioStereoOutputEnabled` / `initialCameraEnabled` / `initialMicrophoneEnabled` / `bypassVoiceProcessing` / `isSpotlightEnabled` / `simulcastEnabled` / `simulcastRid` (非推奨だが stored property のため保持) / `simulcastRequestRid` / `spotlightNumber` / `spotlightFocusRid` / `spotlightUnfocusRid` / `dataChannelSignaling` / `ignoreDisconnectWebSocket` / `audioStreamingLanguageCode` / `proxy` / `insecure` / `caCertificate` (PEM 文字列のまま) / `cameraSettings` / publisher の 3 つの ID。派生値の `isMultistream` と `isSender` も接続開始時に確定させる
  - 変換して持つ: `webRTCConfiguration` → `WebRTCConfigurationSnapshot`、`forwardingFilter` / `forwardingFilters` → `ForwardingFilterSnapshot`、metadata / notify metadata / `dataChannels` → `JSONValue?`、codec 別 params → `JSONValue?` (connect message に載る条件を満たさない場合は `nil`)、`requiresStereoAudioSDP` → `Bool`、`usesCustomAudioDevice` → `Bool` (`audioDevice != nil` を接続開始時に確定した派生値)
  - 含めない: `audioDevice`、handler bag
- `multistreamEnabled` は非推奨だが生値のまま snapshot へ凍結する。`SignalingConnect.multistreamEnabled` は `Bool?` で `encodeIfPresent` されるため、`nil` と `true` を区別できないと既定値のときに `"multistream": true` が新規出力されて signaling JSON が変わる。`isMultistream` (`multistreamEnabled ?? true`) は別途確定し、`PeerChannel` の分岐に使う。`simulcastRid` も非推奨だが、`Bool?` と同じく値の有無が出力に影響するため生値のまま保持する。どちらも snapshot 生成時の読み取りで deprecation 警告が出るが、この 2 つの読み取りは現行の `Configuration.isMultistream` と `PeerChannel.makeSignalingConnect` に既にあり、本 issue は読み取り位置を移すだけで警告の件数を増やさない。
- 非推奨の `spotlightEnabled` は運ばない。`isSpotlightEnabled` は `Configuration` の stored property である `Bool` をそのまま凍結する (`Configuration.Spotlight` ではなく stored property を写す)。`SignalingConnect.spotlightEnabled: Configuration.Spotlight` は変更しないため、`makeSignalingConnect` で `Bool` から復元する。
- `requiresStereoAudioSDP` は `Configuration` の computed property として残す。`SoraTests/StereoAudioOutputE2ETests` が `MediaChannel.configuration.requiresStereoAudioSDP` を参照しており、`SoraTests/DummyAudioDeviceTests` は `Configuration.requiresStereoAudioSDP` を直接参照している。公開挙動を変えない。

### snapshot の生成

- `ConnectionConfigurationSnapshot.init(configuration:) throws` を `Configuration` からの唯一の変換入口とする。テストから単体で生成できるよう、internal な `ICEServerSnapshot.init(_:)` / `WebRTCConfigurationSnapshot.init(_:)` / `ForwardingFilterSnapshot.init(_:)` の変換も用意する。`Encodable` / `Any` から `JSONValue` への変換関数は `Sora/JSONValue.swift` に置く。`Sora/RPC.swift` の `encodeParams` も `Encodable` を `JSONEncoder` → `JSONSerialization.jsonObject(with:options: [.fragmentsAllowed])` で `Any` にしているが、RPC が必要とするのは `Any` のペイロードであり `JSONValue` ではない。変換の後半 (再帰的な型判定と `decimal` の保持) は要件が異なるため共通化せず、RPC の経路は本 issue では変更しない (`0157` が RPC を扱う際に再検討する)。
- `dataChannels` の JSON 化可否検証と metadata などの encode 可否検証は、`0158` が `MediaChannel.validate(configuration:)` に追加する。本 issue は同じ検証をこの変換へ移設し、`MediaChannel.validate` 側からは削除して 1 箇所に保つ。検証条件は `0158` のものを変えず、値型の snapshot から `MediaChannel` へ依存させない。
- `Sora.connect` は `MediaChannel(configuration:)` の生成より前にこの変換関数を呼び、結果を `MediaChannel` の designated init (`init(snapshot:...)`) へ渡す。`MediaChannel(configuration:)` は通らないため、snapshot 生成と検証は 1 回だけである。
- `MediaChannel.init(snapshot:configuration:audioDevice:mediaChannelHandlers:webSocketChannelHandlers:...)` を designated init とする。公開互換の `public let configuration` は designated init でしか初期化できないため、snapshot に加えて元の `Configuration` も受け取る。`configuration` は公開 getter 専用とし、接続開始後の非同期処理からは参照しない。`MediaChannel` は snapshot を internal な stored property として保持し、接続後の読み出しは snapshot から行う。
- `MediaChannel.init(configuration:...)` を internal な convenience として残す。convenience は snapshot を生成し、`configuration` から handler bag と `audioDevice` を取り出し、既存の DI 引数 (`audioSessionCoordinator` / `videoHardMuteLease` / `cameraCaptureCoordinator` / `cameraCaptureOwnership` / `videoSourceCoordinator`) はそのまま designated init へ転送する。`MediaChannel` を直接生成する既存テストはこの経路を通る。変換の実装は 1 つに固定する。
- audio の組合せ制約の検証は designated init が `validate(snapshot:)` を呼んで行う。`validate` が見る `audioDevice` は snapshot の `usesCustomAudioDevice` で足りるため、引数で `RTCAudioDevice` を渡さない (真実の源を 2 つにしない)。
- `SignalingChannel.init(snapshot:webSocketChannelHandlers:)` とし、`required` は削除する。`insecure` / `urlCandidates` / `proxy` は snapshot から読む。`PeerChannel.init(...)` も snapshot を受け取る形へ変更し、`required` は削除する (サブクラスは存在しない)。
- `SignalingChannel` / `PeerChannel` は snapshot を必須引数として受け取り、`configuration` プロパティを保持しない。
- `ConnectionConfigurationSnapshot` は internal とする。利用者が actor / Task 境界へ設定値を渡すための公開型は本 issue のスコープ外である。
- 変換に失敗した場合は `SoraError.configurationError(reason:)` を throw する。通知は `Sora.connect` の既存の設定エラー経路を再利用し、`ConnectionTask.complete()` と `DispatchQueue.global().async` で接続 handler と `Sora.handlers.onConnect` を接続スタック外で呼ぶ。`Sora.add(mediaChannel:)`、ADM、WebSocket、`RTCPeerConnection` は生成しない。
- この通知経路は非 `@Sendable` な接続 handler を `DispatchQueue.async` へ capture しており、既存コードにも `#SendableClosureCaptures` の警告がある。本 issue では新しい box を導入しない。警告の除去は `0155` が扱う。
- `MediaChannel.configuration` は公開互換のため利用者が渡した `Configuration` を返し続ける。接続開始後の非同期区間 (非同期 hop の後、WebRTC callback、`ConnectionTimer`) は `Configuration` の参照型フィールドを読まず snapshot を読む。`MediaChannel.configuration` は `public let` の struct コピーであり値型フィールドは接続開始時の値のままなので、値型フィールドを読む箇所 (公開 getter、`description`、公開 mute API (`setAudioHardMute` / `setAudioSoftMute` / `setVideoHardMute` / `requireSenderStreamForVideoMute`)、`senderStream` / `receiverStreams` の `publisherStreamId` 参照) は `Configuration` のままとし、対象箇所をコメントに列挙する。`MediaChannel.init(configuration:)` (convenience) も handler bag と `audioDevice` を取り出すために `Configuration` を読むが、designated init `init(snapshot:...)` は snapshot を読む。
- `MediaChannel.connect(webRTCConfiguration:)` の internal シグネチャは既存テストの呼び出しを維持するため残すが、`basicConnect` へは渡さない。`MediaChannel.connect` の `timeout` も引数として残す (既存テスト互換。`basicConnect` へは渡さない。Swift は未使用の引数を警告しない)。`basicConnect` の未使用な `webRTCConfiguration` と `timeout` の引数は削除する。この削除により `Sora.connect(webRTCConfiguration:)` の引数を「指定時だけ `Configuration` を上書きする」形へ変える選択肢は狭まるが、`0153` は `Configuration.webRTCConfiguration` への一本化を第一候補としているため矛盾しない。`Sora.connect` の公開引数の扱いは `0153` で決める。
- `ConnectionConfigurationSnapshot` に `CustomStringConvertible` は付与しない。`Equatable` も必須としない (保持する公開型の多く (`Proxy` / `MediaConstraints` / `Role` / `SDPSemantics` / `ICETransportPolicy` / `CameraSettings` / `SimulcastRid` / `SpotlightRid` / `ForwardingFilterRule` など) が `Equatable` ではなく、付与には公開型への conformance 追加が必要になるため)。テストは接続 JSON の正規化比較とフィールド単位の検証で行う。
- snapshot 生成は `Sora.connect` の同期区間で行うため、大きな metadata を渡す利用者の `connect` 呼び出しはその分だけブロックする。encode を非同期区間へ遅らせると利用者所有の値を再度読むことになり本 issue の目的に反するため、同期を維持する。
- redirect では snapshot と handler bag を接続開始時のものから作り直さない。

### 値の凍結

- `0158` が `MediaChannel.validate(configuration:)` に追加する JSON 化可否検証を本 issue が `ConnectionConfigurationSnapshot.init` へ移設する (実装の所在は「snapshot の生成」を参照)。`MediaChannel.validate` に残るのは `audioStereoOutputEnabled` / `audioEnabled` / `audioCodec` / `audioDevice` の組合せ制約だけであり、internal な `validate(snapshot:)` へ置き換える。検証順序は JSON 化可否を audio の組合せ制約より先とする (`0158` も同じ順序にし、`Sora.connect` は snapshot 生成を `MediaChannel.init` より先に行うため、両 issue で同じ優先順位になる)。
- metadata、notify metadata、codec 別 params、`ForwardingFilter.metadata` は snapshot 生成時に `Encodable` を `JSONValue` へ encode する。`JSONEncoder` で `Data` にし、`JSONDecoder` で `JSONValue: Decodable` へ decode する。`JSONValue.init(from:)` は `singleValueContainer` から `decodeNil` → `Bool` → `Decimal` → `Double` → `Int64` → `UInt64` → `String` → `[JSONValue]` → `[String: JSONValue]` の順に試す。`Decimal` を `Double` より先に試すのは数値トークンを `Decimal` の精度で保つためで、`Decimal` が表現できない指数の値は `Double` に落ちる。`JSONDecoder` を使うのは、`JSONSerialization.jsonObject` が `Decimal` を `NSNumber` (Double) として返して Double の精度で表現できない値が変わるためである (実測: `Decimal(string: "1.0000000000000001")` が `1` になる)。トップレベルが scalar / array / null の値も現行どおり受け付ける (`JSONEncoder` と `JSONDecoder` の両方がトップレベル fragment を扱えることを実測で確認済み)。
- `Decimal` は `decimal` として保持し、値と精度を落とさない。`JSONDecoder` の `decode(Decimal.self)` がトークンの文字列をそのまま `Decimal` にするため、Double の精度で表現できない値 (`1.0000000000000001` / `9005713213483.4526`) も利用者入力どおりに出力される。現行は `dataChannels` が非 nil のときにこれらが壊れる (`1` / `9005713213483.4531`)。`Decimal` の `NaN` (`Decimal.quietNaN`) は `JSONEncoder` が throw せず `NaN` という不正な JSON を出力するため (実測)、`JSONDecoder` の decode が失敗し `SoraError.configurationError` として返る。
- `Double` / `Float` の値は変えず、表記だけが次の点で変わる (JSON の数値表現として等価)。
  - metadata: `JSONDecoder` が指数表記を `Decimal` / `Double` として読み直すため指数表記が展開される (実測: `Double 1e-07` が `1e-07` から `0.0000001`)。`-0.0` は `0` になり符号が失われる。`dataChannels` が非 nil のときはさらに、現行の `JSONSerialization` 再直列化 (connect message 全体) がなくなるため 17 桁表記が `JSONEncoder` の表記に揃う (実測: `Double 0.1` が `0.10000000000000001` から `0.1`)。
  - `dataChannels` の値自身: 値 (Double としての解釈) は現行と同一だが、表記は指数表記の展開や丸めにより変わる場合がある (実測: `Double 1e-07` が `9.9999999999999995e-08` から `0.000000099999999999999995`)。ランダムな浮動小数では約 64% (Double) / 約 73% (Float) で表記が変わる。
- `Double` / `Float` は表記ではなく値で比較する。
- `dataChannels: Any?` は別経路とし、次の順で `JSONValue` へ変換する。`JSONSerialization.isValidJSONObject(["data_channels": value])` で検証し、通れば `JSONSerialization.data(withJSONObject: ["data_channels": value])` で `Data` にし、`JSONDecoder` で `["data_channels": JSONValue]` として decode して `data_channels` の値を取り出す (`dataChannels` を埋め込んだ辞書を経由するため、取り出しの一段が必要である)。`JSONSerialization` が受理する型 (Swift の `String` / `Substring` / `NSNull` / `NSNumber` / `NSDecimalNumber` / `Optional.none` / 配列 / 辞書) をそのまま扱えるため、`0158` の検証と拒否側の判定が同じ `isValidJSONObject` の規則に依存して一致し、受理側も実測で一致を確認した (手動 27 ケースとランダム約 12 万件で不一致 0)。受理条件を自前の型判定で再実装してはならない (`Substring` や入れ子の `Optional.none` を誤って拒否し、現行で送信できていた入力の退行になる)。`JSONSerialization` が `Int8(1)` を `1`、`true` を `true`、`UInt64.max` を `18446744073709551615`、`Decimal` を精度を保った数値として書くため、`Bool` と整数の取り違えや 64 bit 整数の精度損失も起きない (実測)。`isValidJSONObject` が false のときと decode に失敗したときは、どちらも `SoraError.configurationError(reason: "data channels are not JSON-serializable")` として返す (`isValidJSONObject` が true で decode が失敗する入力は実測では見つかっていない防御的分岐である)。`isValidJSONObject` で検証してから `data(withJSONObject:)` を呼ぶ順序は `Sora/RPC.swift` の `RPCChannel.call` と同じである。
- `dataChannels` の非有限値 (`Double` / `Float` の `NaN` / `Infinity`、`Decimal.quietNaN`) と JSON 化できない型 (非 String キーの辞書、`Date` / `Data` / `Set` / `URL`、入れ子の非有限値) は `isValidJSONObject` が false を返すため snapshot 生成時に `SoraError.configurationError` として返す (`0158` と同じ判定である)。
- metadata / notify metadata / codec 別 params / `ForwardingFilter.metadata` の encode でも、`Double` / `Float` の `NaN` / `Infinity` は `JSONEncoder` が `invalidValue` を throw する。`Decimal.quietNaN` は throw しないが `NaN` という不正な JSON を出力するため `JSONDecoder` の decode が失敗する (実測)。どちらも snapshot 生成時に `SoraError.configurationError` として返る。`0158` の検証 (encode した `Data` を `JSONSerialization` で読み直す) も同じ入力で失敗するため、両 issue で拒否される入力は同じである。`reason` は `0158` が固定した文字列をそのまま使う (metadata / notify metadata / codec 別 params / `ForwardingFilter` の metadata でそれぞれの文字列、`dataChannels` は `data channels are not JSON-serializable`)。写像は変換関数 1 箇所で行う。エラーの種類・`reason` 文字列・検証順序は `0158` の完了時と同じに保つ。
- `metadata` は `nil` と「`null` を encode する `Encodable`」を区別する。前者は `metadata` キーを出力せず、後者は `null` を出力する (現行の `if let metadata` と同じ)。`Configuration.signalingConnectMetadata` は `Encodable?` のため `NSNull` は代入できず、`null` を出力する値は `encodeNil()` を実装した `Encodable` で作る。テストのフィクスチャもこの形にする。
- `JSONValue` は `SignalingConnect` の `Encodable?` プロパティ (`metadata` / `notifyMetadata` / `opusParams` / `vp9Params` / `av1Params` / `h264Params` / `h265Params`) へそのまま渡せる。`SignalingConnect` の `encode(to:)` は `superEncoder` 経由で値の `encode(to:)` を呼ぶため、公開プロパティ型と `makeSignalingConnect` のシグネチャを変更せずに事前 encode 済みの値を注入できる。
- 事前 encode した `Data` を保持する案は採らない。`superEncoder` へ `Data` を渡すと base64 文字列になり signaling JSON が壊れるためである。この理由をコードコメントに残す。
- codec 別 params は `SignalingConnect.encode(to:)` が connect message に載せる条件と同じ条件で `JSONValue` 化する。`videoVp9Params` / `videoAv1Params` / `videoH264Params` / `videoH265Params` は `videoEnabled` が true かつ対応する `videoCodec` のとき、`audioOpusParams` は `audioEnabled` が true かつ `audioCodec` が `.opus` のときだけ保持し、それ以外は `nil` とする。`PeerChannel.makeSignalingConnect` の三項演算子だけを見て codec 一致で判定すると、connect message に載らない params まで encode することになり、`0158` が意図的に検証しない値 (無効な種別の params の `NaN` など) で snapshot 生成が失敗し、`0158` の完了時には返らなかった `configurationError` を新たに返す。条件の意味は維持し、参照元だけを snapshot へ置き換える。
- metadata が `nil` のときに `"metadata": {}` を送らない条件と、`ForwardingFilter.metadata` の nil 条件を維持する。
- `dataChannels` は `JSONValue?` として `dataChannelSettings` に保持する。名前は `PeerChannel.dataChannels: [String: DataChannel]` と `SignalingOffer.dataChannels` と区別するため `dataChannelSettings` とする。internal な `SignalingConnect.dataChannelSettings` へ `PeerChannel.makeSignalingConnect` で渡す。`SignalingConnect.encode(to:)` で `data_channels` を出力し、`SignalingChannel.send` の `JSONSerialization` によるマージは削除する。`configuration.dataChannels` が `NSNull` のときは `if let` で unwrap した値を変換し、`"data_channels": null` を出力する (現行の `configuration.dataChannels != nil` 判定と同じ。`NSNull` を未設定と同一視しない)。
- `ForwardingFilterSnapshot` から `SignalingConnect.forwardingFilter` / `forwardingFilters` へ戻す再変換を 1 箇所の関数として実装する。`SignalingConnect` のこれらは `ForwardingFilter` / `[ForwardingFilter]` 型であり `JSONValue` ではないため、`JSONValue` をそのまま渡せない。再変換は `name` / `priority` / `action` / `rules` / `version` を snapshot の値から埋め、`metadata` には snapshot が保持する `JSONValue?` をそのまま渡す (`ForwardingFilter.init(metadata:)` は `Encodable?` を取るため、`JSONValue` が `Encodable` に準拠していることを使ってそのまま渡せる。nil ならキーを省略し、`JSONValue.null` なら `null` を出力する。`ForwardingFilter.encode(to:)` の nil 抑止と同じ出力になる)。この出力が現行と同じであることをゴールデンで固定する。
- `ICEServerSnapshot` に `CustomStringConvertible` を付与せず、`credential` / `username` を含む値の新しい文字列化経路を追加しない。
- `ICEServerSnapshot` は URL、ユーザー名、credential、TURN-TLS のポリシー (`isTLSInsecure`) を copy する。`0030` 完了後は `userName` が非推奨になるため格納プロパティ `username` を読む。`0030` の完了前に着手する場合は `userName` を読み、変換関数 1 箇所に非推奨警告が残ることを許容する。`tlsSecurityPolicy` は現時点で既に非推奨のため、`0138` の完了前は 1 箇所で読むことを許容する。`RTCTlsCertPolicy` への写像と `usesVerifiedTURNTLS` の判定は snapshot 側の computed property に一本化し、`insecure` を優先する既存の関係を再現する。
- `parsedCACertificates()` は現在 `extension Configuration` のメソッドであり、`configuration` を保持しない `SignalingChannel` / `PeerChannel` からは呼べない (本 issue の変更後)。パース処理は既に `Configuration.parsePEMCertificates(_:)` (private static) に切り出されているため、この可視性を internal に変更し、`Configuration.parsedCACertificates()` と snapshot 側のメソッドの両方から呼ぶ。`Configuration.parsedCACertificates()` はテスト互換のラッパーとして残し、snapshot を生成する委譲にはしない (snapshot を生成すると metadata / `dataChannels` の検証を巻き込み、CA 解析だけを目的にした呼び出しが `configurationError` を投げ得るため)。パース処理の実装は 1 箇所に固定する。
- `CameraSettings` は `0123` の完了により `Sendable` のため snapshot へそのまま保持する。`PeerChannel` が接続中に読む `cameraSettings.isEnabled` / `.position` / `.resolution` / `.frameRate` を snapshot の `CameraSettings` へ置き換える。`Sora/VideoMute.swift` の internal な `CameraSettingsSnapshot` はミュート解除時のカメラ再起動経路が使うため変更しない。
- `audioDevice` は snapshot に含めない。`RTCAudioDevice` が必要な `NativePeerChannelFactory` の生成は `MediaChannel.init` の同期区間で行う。`PeerChannel` の接続処理が snapshot から必要とするのは `requiresStereoAudioSDP` (SDP 用) と `usesCustomAudioDevice` (`audioDevice != nil` を接続開始時に確定した派生値) の 2 つである。`PeerChannel.initializeSenderStream` の `configuration.audioDevice` 参照は `usesCustomAudioDevice` で置き換える。`requiresStereoAudioSDP` で代用してはならない。`requiresStereoAudioSDP` は `audioStereoOutputEnabled || audioDevice?.outputNumberOfChannels == 2` であり `audioDevice != nil` と等価ではなく、代用するとネイティブ ADM のステレオ接続でマイク入力が初期化されず、モノラルのカスタムデバイスで逆に初期化される退行になる。
- `MediaChannel.init` の同期区間で使う `audioStereoOutputEnabled` / `isSender` / `bypassVoiceProcessing` / `connectionTimeout` は snapshot から読む。`AudioSessionUsage` の算出と `ConnectionTimer` の生成も snapshot を用いる。`audioDevice` と handler bag だけは snapshot ではなく init の引数で受け取る。
- `DeviceInfo.current` は利用者由来の設定ではないため snapshot に含めない。`environment` は既存どおり connect message 生成時に読み、redirect 再送時も再評価される既存挙動を維持する。読み取りの安全化は `0112` で扱う。

### handler bag の引き渡し

- mutable handler bag を `ConnectionConfigurationSnapshot` に含めない。非 `@Sendable` な closure を保持する型は checked `Sendable` に準拠できないためであり、完了条件の「deep Sendable」は snapshot 型 (`ConnectionConfigurationSnapshot` / `ICEServerSnapshot` / `WebRTCConfigurationSnapshot` / `ForwardingFilterSnapshot`) を指す。
- `MediaChannel.init` は `mediaChannelHandlers` を、`SignalingChannel.init` は `webSocketChannelHandlers` を明示引数として受け取る。`SignalingChannel` から `configuration` を削除するため、`ws.handlers` への代入元を引数へ移す必要がある。
- 引き渡すのは handler bag の参照であり、closure を copy しない。配送のたびに bag を読む既存挙動を維持し、接続開始後の handler 変更が次の配送から反映されることを保証する。`skills/sora-ios-sdk/SKILL.md` の接続フロー (接続成功後に `MediaChannel.handlers` でコールバックを登録する手順) と、接続後に `MediaChannel.handlers` を設定する既存テストを壊さない。
- `SignalingChannelInternalHandlers.onDisconnect` と `PeerChannel.internalHandlers.onDisconnect` は `peerChannel.connect` より前の同期区間で設定する。`SignalingChannelInternalHandlers.onDisconnect` は `PeerChannel.init` と `MediaChannel.connect` の 2 箇所で設定され後者が上書きするが、どちらも `peerChannel.connect` より前である。`PeerChannel.internalHandlers` の `onAddStream` / `onRemoveStream` / `onOpenDataChannel` / `onReceiveSignalingJSON` / `onReceiveSignaling` は `basicConnect` の中で 1 回だけ設定する。対応する callback が始まる前に設定し終えるため、排他も copy もしない。この前提を崩す変更を入れる場合は排他を追加する。
- closure property の読み書きの排他は本 issue では行わない。`0154` が扱う (`0110` の event API と `0111` の `SoraHandlers` 同期の対象ではない)。

### offer 由来で更新される設定

- 利用者由来 snapshot の `WebRTCConfigurationSnapshot` は `Configuration.webRTCConfiguration` の全フィールド (constraints / `[ICEServerSnapshot]` / ICE transport policy / SDP semantics / degradation preference) を写す。`isInsecure` は元の `WebRTCConfiguration.isInsecure` の値を写す (internal フラグで、既定は false)。
- `PeerChannel` は同じ `WebRTCConfigurationSnapshot` 型の接続所有インスタンスを持ち、`PeerChannel.init` で利用者由来 snapshot の値を値コピーして初期化する。snapshot の stored property はすべて `let` のため、offer 受信時の更新は現在値から差し替えた新しい値を作って代入する形にし、`webRTCConfigurationLock` を保持して行う。`offer.configuration` が非 nil のときは `iceServerInfos` を `offer.configuration.iceServerInfos.map(ICEServerSnapshot.init)` で変換した値と、`iceTransportPolicy` のサーバー値で置き換える。`isInsecure` は `offer.configuration` の有無にかかわらず毎回 `ConnectionConfigurationSnapshot.insecure` (`Configuration.insecure` の写し) で置き換える (現行の `PeerChannel` が `if let config = offer.configuration { ... }` の外で `webRTCConfiguration.isInsecure = configuration.insecure` としているのと同じ。ここを offer 由来の値にすると `Configuration.insecure` が効かなくなる)。`offer.configuration` が `nil` の場合は `iceServerInfos` / `iceTransportPolicy` だけ現在値をそのまま使う (redirect の 2 回目の offer で `nil` のときは直前の offer のサーバー値が残る既存挙動を維持する。利用者値へ戻さない)。
- 一時 offer の生成 (`createClientOfferSDP`) と本 `RTCPeerConnection` の生成 (`createNativePeerChannel`) / `setConfiguration` は、どちらも接続所有インスタンスから `nativeValue` / `nativeConstraints` / `usesVerifiedTURNTLS` を読む。一時 offer は offer 受信前に作られるため、接続所有インスタンスの `isInsecure` が `WebRTCConfiguration.isInsecure` の初期値のままである既存挙動を維持する (`Configuration.insecure` が true でも一時 offer には反映されない)。
- `NativePeerChannelFactory` の `createNativePeerChannel` は `configuration:` の型を `WebRTCConfigurationSnapshot` に変更し、`constraints:` 引数は削除して snapshot の `nativeConstraints` を使う。`createClientOfferSDP` も `configuration:` を同じ型へ変更し、`constraints:` 引数は削除して snapshot の `constraints` を `createNativeSenderStream` へ、`nativeConstraints` を `offer(for:)` へ渡す。既存テスト (`SoraTests/StereoAudioOutputTests` の `createClientOfferSDP(configuration:constraints:handler:)` と `createNativePeerChannel(configuration:constraints:delegate:)`) の呼び出しをこのシグネチャへ移行する。
- `createNativeSenderStream` は現行どおり `constraints: MediaConstraints` を受け取る。snapshot が保持する `MediaConstraints` をそのまま渡し、mirror 型を作らない。
- 接続所有インスタンスは `PeerChannel` に追加する専用の `NSLock` (`webRTCConfigurationLock`) 配下でのみ読み書きする。既存の `PeerChannel.lock` は接続ライフサイクルの状態 (進行中の非同期処理数と切断フラグ) を保護するための型であり、`webRTCConfiguration` の読み書きを保護する用途ではないため使用しない。lock は接続所有インスタンスの値を 1 回 copy する短い区間だけ保持し、`initializeSenderStream` / `createAnswer` / `createClientOfferSDP` のような関数全体、libwebrtc の非同期 callback、`await`、利用者 handler の呼び出しをまたいで保持しない。`webRTCConfigurationLock` を保持したまま `PeerChannel.lock` を取得する経路を作らない (`PeerChannel.lock` が必要な処理は lock を解放してから行う)。lock の統合と取得順序の全体設計は `0129` が扱う。
- `PeerChannel.webRTCConfiguration` は `WebRTCConfigurationSnapshot` 型へ置き換え、`createClientOfferSDP` / `createNativePeerChannel` / `setConfiguration` と constraints の全参照 (`initializeSenderStream` の `degradationPreference` 参照を含む) を移行する。旧 `WebRTCConfiguration` 型のプロパティは残さない。

### 互換性

- 公開 `Configuration` の property と initializer を維持する。
- `Configuration: Sendable` または `@unchecked Sendable` は付与しない (struct の浅い copy では参照先を凍結できないため)。
- `SignalingConnect` の公開プロパティ型と `PeerChannel.makeSignalingConnect` のシグネチャを変更しない。internal な `var dataChannelSettings: JSONValue? = nil` を追加する (`let` + 既定値は memberwise init の既定引数から除外されるため `var` にする)。既存の memberwise init 呼び出しを変えない。
- `WebRTCConfiguration` / `ICEServerInfo` / `ForwardingFilter` / `MediaConstraints` の公開 property と initializer、および `Codable` の出力 (キー名を含む) を維持する。`WebRTCConfiguration` の internal メンバの移設は公開 API に影響しない。
- `MediaChannel.configuration` は元 `Configuration` を返し続ける。そのため `MediaChannel` は Sendable ではなく、利用者が `configuration` を actor / Task 境界へ渡す要件は `0152` で扱う。`Sora.connect` の公開シグネチャは変えない。`MediaChannel.validate` は internal のため、snapshot を受け取る形へ変更する。
- `CHANGES.md` の `## develop` の主リストに、refactor を `[UPDATE]` として、`dataChannels` が非 nil のときの connect message に載る `Decimal` の値の修正を `[FIX]` として追記する。`[UPDATE]` の本文には、接続開始時に設定を snapshot へ写し取るようになったことと、数値の表記が変わり得ること (指数表記の展開、`-0.0` の符号) を含める。`[FIX]` は「`dataChannels` を設定していると connect message に載る `Decimal` (`signalingConnectMetadata` / `signalingConnectNotifyMetadata` / codec 別 params / `ForwardingFilter.metadata`) が Double の精度に丸められて送信される問題を修正する」とし、`[UPDATE]` と同様に主リストへ置く (`### misc` は利用者影響が無いリファクタなどに使われている)。分離可能なバグ修正は `0158` に切り出したが、この問題は `JSONSerialization` 往復の廃止 (本 issue の中核) でしか直せないため、本 issue が `[FIX]` を 1 件持つ。担当者行は `- @t-miya` とし、種別の順序 (`[UPDATE]` → `[FIX]`) と担当者行の書式は `shiguredo-changelog` に従う。
- `0107` の API baseline は未整備のため、本 issue では `git diff` と目視で公開 API 差分ゼロを確認する。`dataChannelSettings` と `JSONValue` は internal のため差分に出ない。baseline による機械検査は `0107` の完了後に行う。

## スコープ外

- `0110` (Sendable event API と executor 契約) で扱う、handler の `@Sendable` 化。
- `0111` (Sora の共有状態) で扱う、`SoraHandlers` の同期。
- `0154` で扱う、`MediaChannelHandlers` / `WebSocketChannelHandlers` の closure property の読み書きの排他。
- `0158` (前提 issue) で扱う、JSON 化できない接続設定を接続開始前に `SoraError.configurationError` として返す修正。
- `ICEServerInfo` を公開 struct に変更する破壊的 API 変更。
- `0156` で扱う、ログと文字列表現からのシークレット漏えいの防止 (`Logger.maskSecrets` の対象キー、`ICEServerInfo.description`、`urlCandidates` のログ、マスクの単体テスト)。
- `PeerChannel.lock` の役割と `PeerChannel` 全体の排他設計は `0129` (PeerChannel.Lock の統合) で扱う。本 issue は接続所有 WebRTC 設定の読み書きに専用 lock を追加するところまでとする。
- 非推奨の `Configuration.multistreamEnabled` / `Configuration.simulcastRid` の内部読み取りの解消。`0138` がこの 2 つを対象外と明記しており、本 issue は読み取り位置を移すだけで警告の件数を増やさない。

## 変更対象

- `Sora/JSONValue.swift` (新規): `JSONValue` 型と `Encodable` / `Any` からの変換 (`JSONValue` 自身は `Encodable` / `Decodable` に準拠する)
- `Sora/ConnectionConfigurationSnapshot.swift` (新規): snapshot 型、`ICEServerSnapshot`、`WebRTCConfigurationSnapshot`、`ForwardingFilterSnapshot`、変換処理
- `Sora/Configuration.swift`: `parsePEMCertificates(_:)` を internal に変更し、テスト互換の `parsedCACertificates()` ラッパーを残す。`requiresStereoAudioSDP` は computed property として残す (`SoraTests/StereoAudioOutputE2ETests` が `MediaChannel.configuration.requiresStereoAudioSDP` を参照する)
- `Sora/Sora.swift`: snapshot 生成と呼び出し順序 (設定エラー経路の呼び出しは変更するが box 化はしない)
- `Sora/MediaChannel.swift`: designated init の変更、snapshot の保持、非同期区間の `configuration` 参照の置き換え、`validate(snapshot:)` への変更、`0158` が `validate(configuration:)` に追加した JSON 化可否検証コードの削除 (metadata などは `JSONValue` への decode 成否で、`dataChannels` は `isValidJSONObject` で判定する)
- `Sora/PeerChannel.swift`: snapshot の受け取り、接続所有の WebRTC 設定の分離、`configuration` 参照の置き換え (`WrapperVideoEncoderFactory.shared.simulcastEnabled` へ渡す `configuration.simulcastEnabled` を含む)、`webRTCConfigurationLock` の追加
- `Sora/SignalingChannel.swift`: snapshot と handler bag の受け取り、`configuration` 参照の置き換え、`required` の削除、`send` の `JSONSerialization` マージの削除
- `Sora/Signaling.swift`: internal な `var dataChannelSettings: JSONValue? = nil` の追加 (既存の memberwise init 呼び出しを変えない) と `data_channels` の encode
- `Sora/WebRTCConfiguration.swift` / `Sora/ICEServerInfo.swift` / `Sora/NativePeerChannelFactory.swift`: `nativeValue` / `nativeConstraints` / `usesVerifiedTURNTLS` の `WebRTCConfigurationSnapshot` への移設、`createNativePeerChannel` / `createClientOfferSDP` のシグネチャ変更、移設に伴い未参照となる `ICEServerInfo.nativeValue(insecure:)` と `ICEServerInfo.usesVerifiedTURNTLS` の削除 (挙動不変)
- `SoraTests/ConfigurationTests.swift`: 変更しない (CA 解析テストは `Configuration.parsedCACertificates()` のラッパーを引き続き使う)
- `SoraTests/ConnectionConfigurationSnapshotTests.swift` (新規): 不変性、deep Sendable、`JSONValue` 変換の単体テスト、connect JSON のゴールデン比較、`encodeNil()` を実装した `null` 用の `Encodable` フィクスチャ
- `SoraTests/SendableConformanceTests.swift`: `ConnectionConfigurationSnapshot` の 4 型を actor / Task 境界へ渡すコンパイル時検証を追加 (`requireSendable` は internal のため再利用できる)
- `SoraTests/PeerChannelConnectEncodingTests.swift` / `SignalingConnectTests.swift` / `PeerChannelConnectCompletionTests.swift` / `PeerChannelRedirectInvalidationTests.swift` / `ConnectionTaskTests.swift` / `ConnectionTimerLifecycleTests.swift`: ヘルパー内で `try ConnectionConfigurationSnapshot(configuration:)` を 1 回生成し、`SignalingChannel(snapshot:webSocketChannelHandlers:)` / `PeerChannel(snapshot:...)` へ置換する (`SignalingConnectTests` / `PeerChannelConnectEncodingTests` のヘルパーは既に `throws` のため呼び出し元の変更は不要)。`ConnectionTimerLifecycleTests` の `makeSignalingChannel()` は非 throwing のため、ヘルパーとその呼び出し元 (`makeConnectionTimer` とこれを使うテスト) を `throws` 化する。
- `SoraTests/DummyAudioDeviceTests.swift` / `SoraTests/StereoAudioOutputTests.swift`: `MediaChannel.validate(snapshot:)` への呼び出しの移行 (`StereoAudioOutputTests` の `MediaChannel.validate(configuration:)` 2 箇所) と、`NativePeerChannelFactory` の呼び出しの移行 (`createClientOfferSDP(configuration:constraints:handler:)` 1 箇所 / `createNativePeerChannel(configuration:constraints:delegate:)` 3 箇所)。`createClientOfferSDP` / `createNativePeerChannel` へ `WebRTCConfiguration()` を渡している箇所だけを `WebRTCConfigurationSnapshot(WebRTCConfiguration())` に置き換える (`MediaChannel.connect(webRTCConfiguration:)` の引数は `WebRTCConfiguration` のままで、置換対象ではない)。
- `SoraTests/ConnectConfigurationValidationTests.swift` (`0158` が新規作成): `0158` が追加した JSON 化可否検証のテストを、snapshot 生成と `validate(snapshot:)` を呼ぶ形へ移行する (`MediaChannel.validate(configuration:)` の互換ラッパーは残さないため、`0158` が `MediaChannel.validate(configuration:)` を直接呼ぶテストを置いた場合はこのファイルで移行する)
- `CHANGES.md`

## 前提となる issue

- `0100` (完了 2026-09-08): `ConnectionStateOwner` / `ConnectionSnapshotStorage` / 純粋 reducer。同じ配置・命名の考え方に揃える。
- `0101` (完了 2026-09-15): `SignalingState` / `SignalingStateOwner`。`SignalingChannel` の `configuration` 参照を snapshot へ置き換える土台になる。
- `0123` (完了 2026-09-15): `MediaConstraints` / `DegradationPreference` / `ForwardingFilterRule` 系 / `CameraSettings` への `Sendable` 準拠の追加。本 issue はこれらの公開型をそのまま snapshot に保持する。
- `0158` (JSON 化できない接続設定の検証): JSON 化できない `dataChannels` と connect message に載る metadata などの encode 失敗を、接続開始前に `SoraError.configurationError` として返す検証を `MediaChannel.validate(configuration:)` に追加する。
- `0138` (非推奨 API の内部利用除去) と `0030` (`ICEServerInfo` の userName): 先に完了させ、`ICEServerInfo` の内部表現を確定させる。完了前に着手する場合は現行の `userName` / `tlsSecurityPolicy` を読み、変換関数 1 箇所に非推奨警告が残ることを許容する。
- `0107`: consumer fixture と API baseline (未完了)。baseline による機械検査は `0107` の完了後に行う。
- `0025` (`SignalingChannelInternalHandlers.onSend` の削除): 先に完了していることが望ましいが、必須ではない。`0025` は `SignalingChannel.send` の 1 行 (`onSend` の適用) を削除するだけで、本 issue が変える `data_channels` のマージとは行が重ならず、意味的な依存も無い (`onSend` はどこからも設定されていないデッドコードである)。同時に進める場合は `SignalingChannel.send` の近接行を触るため rebase する。

### 順序調整

- `0158` (`Configuration` の JSON 化可否検証) の完了後に着手する。`0158` は `0102` より番号が大きいが、`0102` からバグ修正を分離した issue であり、「番号が小さい issue から順に対応する」規約の例外として `0158` を先に完了させる。本 issue は `0158` が `MediaChannel.validate(configuration:)` に追加した検証を snapshot 生成へ移設し、`MediaChannel.validate` 側から削除する。同時に進めると検証が二重になり、片方だけが更新されて条件がずれる。
- `0141` (SignalingChannel の責務純化) は `SignalingChannel.send` / `handle` の JSON codec 分離で同じメソッドを書き換えるため、本 issue の完了後に着手する。
- `0155` (`Sora.connect` の設定エラー通知経路の closure capture) は `0102` が変更する同じ経路を触るため、本 issue の完了後に着手する。
- `0129` (`PeerChannel.Lock` の統合) は本 issue が追加する `webRTCConfigurationLock` を前提に、`PeerChannel` 全体の排他設計を扱う。
- `0152` / `0153` / `0154` は本 issue の完了後に着手する。
- `0156` (ログと文字列表現からのシークレット漏えいの防止) は本 issue が追加する `ICEServerSnapshot` の文字列表現を扱うため、本 issue の完了後に着手する。

### 本 issue を前提とする

- `0110`: mutable handler bag と設定 snapshot の分離を本 issue の担当としている。
- `0026`: `PeerChannel.connect` の `WrapperVideoEncoderFactory.shared.simulcastEnabled` 設定行を本 issue も変更するため、本 issue を先に完了させる (`0026` は接続設定の snapshot を自スコープ外としている)。
- `0157`: `Sora/JSONValue.swift` の `JSONValue` を公開型として再利用する (本 issue では internal のまま)。

## テスト方針

モックやスタブは使用しない。

- 実 `Configuration` から snapshot を生成し、元の metadata object、`ForwardingFilter.metadata`、`ICEServerInfo` を変更しても snapshot と送信 JSON が変化しないことを確認する。
- value type の property 再代入は元々接続側へ伝播しないことと、reference type の in-place 変更だけが凍結対象であることを日本語コメントで明記する。
- `JSONValue` への変換単体のテストは本 issue が `SoraTests/ConnectionConfigurationSnapshotTests.swift` に持つ。`Encodable` / `Any` の値が snapshot 経由で `SignalingConnect` に渡ったときに元と同じ JSON になること、`Int64` / `UInt64` / `Decimal` の精度が保たれること、`true` が bool として保持され、`Int8(1)` / `UInt8(1)` / `UInt64(1)` / `UInt64.max` の数値が現行と同じ JSON になること、`dataChannels` に JSON 化できない型 (`Date` / `Data` / `Set` / `URL` / 非 String キーの辞書) を含む場合と `NaN` / `Infinity` / 入れ子の `NaN` / `Decimal.quietNaN` を含む場合に `SoraError.configurationError` になりプロセスが abort しないことを検証する。`0158` の検証を移設するため、移設後も同じ入力が同じエラーと `reason` 文字列で終端することを固定する。
- `Decimal` を metadata と `dataChannels` に使ったゴールデンを固定する。`Double` の精度で表現できない値 (`1.0000000000000001` / `9005713213483.4526`) と現行でも壊れない値 (`0.10000000000000001`) を含め、すべて利用者が設定した値で出力されることを検証する。metadata の `Decimal` は `dataChannels` が非 nil のとき現行が壊れていた値 (`1.0000000000000001` が `1`) を利用者入力どおりに戻すことを固定する。`Float` / `Double` の表記差 (metadata の `Double 1e-07` が `1e-07` から `0.0000001`、`dataChannels` が非 nil のときの metadata `Double 0.1` が `0.10000000000000001` から `0.1`、`dataChannels` の `Double 1e-07` が `9.9999999999999995e-08` から `0.000000099999999999999995`) を記録し、いずれも値が同一であることを併せて検証する。表記の一致ではなく値の一致で比較する。
- metadata などの object は `JSONValue.object` の `Dictionary` の順序で出力され、順序は不定で利用者の `Encodable` の宣言順とは一致しない (JSON として等価)。比較は `JSONEncoder` の `.sortedKeys` で正規化する。
- `dataChannels` の `Float(0.1)` が現行と同じ `0.10000000149011612` として出力されることを検証する (既存 E2E テストの `dataChannels` は `Bool` / `String` のみで、ここで固定しないと検出できない)。`NSNull` を設定した場合に `"data_channels": null` が出力されることも検証する。
- 表記だけが変わる数値 (metadata の `Float` の指数表記、`Double 1e-07`、`dataChannels` の指数表記の `Double`) は、値が同一であることを個別テストで検証する。`-0.0` は `0` になり符号が失われることを別のテストで固定する。
- `ConnectionConfigurationSnapshot` / `ICEServerSnapshot` / `WebRTCConfigurationSnapshot` / `ForwardingFilterSnapshot` が `Sendable` であることをコンパイル時に検証する。internal 型のため `SoraTests/SendableConformanceTests.swift` の `requireSendable` と actor / Task 境界の compile scenario で行い、`0107` の consumer fixture は public API のみを対象とする。
- codec 別 params が `SignalingConnect.encode(to:)` の条件でのみ `SignalingConnect` へ渡ることを検証する。opus 側の同条件は既存 `SignalingConnectTests` が担保しているため、`videoCodec != .vp9` のときと `videoEnabled == false` のときに vp9 params が送られないことを追加で検証する。
- metadata が `nil` のとき `"metadata"` キーが出力されず、`ForwardingFilter.metadata` が `nil` のとき空 object が出力されないことを検証する。
- metadata が `nil` / `null` を encode する `Encodable` / scalar / 空 object の各場合で、出力が現行と同じ (`null` とキー省略を区別する) であることを検証する。`null` のフィクスチャは `encodeNil()` を実装した `Encodable` を `ConnectionConfigurationSnapshotTests` に置く。
- `NaN` / `Infinity` を含む metadata と、JSON 化できない `dataChannels` が `SoraError.configurationError` になり、プロセスが abort しないことを `Sora.connect` 経由でも検証する。
- ゴールデン JSON は `Configuration` のフィクスチャごとに `SoraTests/ConnectionConfigurationSnapshotTests.swift` に固定し、`Configuration` にフィールドを追加したときは同ファイルの期待値を更新する。
- `dataChannels` を含む connect JSON のテストは `SoraTests/ConnectionConfigurationSnapshotTests.swift` に置き、次の 3 つに分ける。
  - connect JSON の文字列ゴールデン (`.sortedKeys`): 対象は `metadata` / `signaling_notify_metadata` / `data_channels` / codec 別 params に限定する。connect message 全体を固定すると `environment` (`DeviceInfo.current` の端末名と OS バージョン) / `sora_client` と `libwebrtc` (バージョン) が環境依存で壊れるためである。フィクスチャの数値は `Int64` / `UInt64` と表記が変わらない `Double` / `Decimal` に限定する。
  - 表記だけが変わる入力の等価比較: 変更前の経路 (`SignalingChannel.send` の `JSONSerialization` マージ) を再現するヘルパーを `ConnectionConfigurationSnapshotTests` 内に置き、その出力と新経路の出力をどちらも `JSONDecoder` で `JSONValue` に decode して `JSONValue` の `Equatable` で比較する (両辺とも `Decimal` は `Decimal` のまま、`Double` は `Double` のまま比較される)。`JSONSerialization` で `Any` にすると Double の精度で表現できない `Decimal` (例: `1.0000000000000001`) が `Double` になり差を検出できないため、比較には `JSONDecoder` を使う。
  - 意図的に値が変わる入力の期待値固定: `dataChannels` が非 nil のときの metadata の `Decimal` (現行の壊れた値ではなく利用者入力どおりになること) と `-0.0` (符号が失われること) は等価比較の対象外にし、個別テストで期待値を固定する。旧経路の出力はこの入力では利用者入力と異なるため、等価比較に含めると必ず不一致になり、テストを現行の壊れた値に合わせる方向へ弱めてしまう。
- `dataChannels` のフィクスチャには `Bool` / `Int8(1)` / `UInt64.max` / `Int64.max` / `Float(0.1)` / `Double 0.1` / `Decimal` (17 桁と 21 桁) / `Substring` / 入れ子の `Optional.none` / `NSNull` / `Date` / `Data` / `Set` / `URL` / 非 String キーの辞書 / `Decimal.quietNaN` / 入れ子の `NaN` を含め、現行と同じ受理・拒否と出力になることを検証する (`Double` 経由にすると `UInt64.max` が `18446744073709552000` に壊れるため、64 bit 境界を必ず含める。`Substring` と `Optional.none` は自前の型判定では誤って拒否しやすい)。
- `NaN` を含む `Encodable` と、`encodeNil()` を実装した `null` 用の `Encodable` は `ConnectionConfigurationSnapshotTests` 内に置く。
- `CameraSettings` が snapshot へそのまま保持され、`isEnabled` / `position` / `resolution` / `frameRate` が接続開始時の値で凍結されることを検証する。
- `ICEServerSnapshot` が TURN-TLS の検証ポリシーを保持し、`usesVerifiedTURNTLS` の判定が変わらないことを検証する (`SoraTests` から `ICEServerInfo.usesVerifiedTURNTLS` を参照しない。移設後は snapshot 側の判定だけを検証する)。
- `SendonlyE2ETests` の `data_channels` 検証と `ConfigurationTests` の CA 解析検証を回帰検証として使う。
- 接続開始後に `MediaChannel.handlers` を変更した場合、次の配送から反映される既存挙動が維持されることを確認する。`E2ETestBase` の `disconnectAndVerify` / `disconnectAll` が無修正で成功することを回帰条件とする。
- `Sora` と `SoraTests` を `SWIFT_VERSION=6` と `SWIFT_STRICT_CONCURRENCY=complete` でビルドし、変更前後で `#SendableClosureCaptures` などの concurrency 診断の件数を数えて増えていないことを差分で示す。現行 CI に `SWIFT_STRICT_CONCURRENCY` のゲートは無いため、ローカルの `xcodebuild` 実行結果を残す。test target の gate の本対応は `0118` が扱う。
- Thread Sanitizer が利用できる場合は、接続中に元の metadata object と `ICEServerInfo` を別スレッドから変更し、race report が出ないことを確認する。snapshot 化により SDK は元 object を読まなくなるため、この実行は「元 object を変更しても race が出ない」ことの確認であり、値の非共有は snapshot と送信 JSON の比較で検証する。`0119` の CI 基盤が未整備の間は `-enable-thread-sanitizer` を付けた手動実行の結果を残す。
- 既存テストと追加テストがすべて成功することを確認する。

## 完了条件

- `ConnectionConfigurationSnapshot` の stored property がすべて `let` で、immutable かつ deep Sendable であること (handler bag を含まない)。
- snapshot 生成に失敗した場合 (`0158` が扱う JSON 化可否の検証を含む)、ADM、WebSocket、`RTCPeerConnection` を生成する前に `SoraError.configurationError` として終端すること。
- metadata、notify metadata、codec parameter、`forwardingFilter` / `forwardingFilters` の metadata、`dataChannels` が snapshot 生成時に `JSONValue` へ写されること。
- `ICEServerInfo` が参照共有されない internal value type へ copy され、TURN-TLS の検証ポリシーが維持されること。
- snapshot が raw WebRTC / Objective-C object (`RTCAudioDevice` など) を stored property として保持しないこと。
- `requiresStereoAudioSDP` / `usesCustomAudioDevice` とカメラ設定 (`isEnabled` / `position` / `resolution` / `frameRate`) の判定材料が接続開始時に確定していること。`CameraSettings` は型ごと snapshot へ写すため、`0142` / `0143` が `CameraSettings` にフィールドを追加しても本 issue の変更は不要である。`MediaChannel.configuration` は `public let` の struct コピーのため、公開 mute API が読む値型フィールドは snapshot と同じ値になる。
- `ConnectionConfigurationSnapshot` / `ICEServerSnapshot` / `WebRTCConfigurationSnapshot` / `ForwardingFilterSnapshot` が checked `Sendable` に準拠していること。`@unchecked Sendable` を付与していないこと。
- `ConnectionConfigurationSnapshot` が `CameraSettings` を、`WebRTCConfigurationSnapshot` と `ForwardingFilterSnapshot` が `MediaConstraints` / `DegradationPreference` / `ForwardingFilterRule` 系の公開型をそのまま保持し、mirror 型を定義していないこと。
- `JSONValue` が internal のままで、公開 API の差分がゼロであること。
- 接続開始後の非同期区間が `Configuration` の参照型フィールド (metadata / notify metadata / codec 別 params (`audioOpusParams` / `videoVp9Params` / `videoAv1Params` / `videoH264Params` / `videoH265Params`) / `dataChannels` / `forwardingFilter` / `forwardingFilters` / `webRTCConfiguration`) を参照せず、snapshot を参照していること。`MediaChannel.configuration` は `public let` の struct コピーのため、値型フィールドを読む箇所 (公開 getter、`description`、公開 mute API、`senderStream` / `receiverStreams`) と `MediaChannel.init(configuration:)` (convenience) の handler bag / `audioDevice` の取り出しは除く。
- internal な `SignalingConnect.dataChannelSettings` へ snapshot の `dataChannelSettings` を渡していること。
- `MediaChannel.validate(snapshot:)` が audio の組合せ制約のみを持ち、`configuration` を受け取らないこと。
- `MediaChannel.init(snapshot:...)` が `validate(snapshot:)` を呼び、`MediaChannel(snapshot:...)` を直接使う経路でも audio の組合せ制約が検証されること。`usesCustomAudioDevice` は snapshot 生成時に `audioDevice != nil` から確定し、designated init へ渡す `audioDevice` と常に一致する。`precondition(snapshot.usesCustomAudioDevice == (audioDevice != nil))` を置いてこの内部不変条件を表明する (`precondition` はリリースビルドでも評価されるため、不一致は SDK 内部の不具合として停止させる。両方を確定させる経路は `MediaChannel.init(configuration:)` だけであり、公開 API からは不一致を作れない。`MediaChannel(snapshot:...)` を直接使うテストは常に整合した組を渡す)。
- `0158` が追加した JSON 化可否検証のテストが、snapshot 生成と `validate(snapshot:)` を呼ぶ形へ移行されていること。
- handler bag が `ConnectionConfigurationSnapshot` から分離され、明示引数として `MediaChannel` / `SignalingChannel` へ引き渡されること。
- 接続開始後に handler を変更した場合の配送が既存挙動を維持すること。
- `WebRTCConfiguration` の `nativeValue` / `nativeConstraints` / `usesVerifiedTURNTLS` が `WebRTCConfigurationSnapshot` へ移設され、`WebRTCConfiguration` と `ICEServerInfo` の側に重複実装が残っていないこと (参照されなくなった `ICEServerInfo.nativeValue(insecure:)` / `ICEServerInfo.usesVerifiedTURNTLS` を削除していること)。
- offer 受信時の `iceServerInfos` / `iceTransportPolicy` の上書きと、redirect で `offer.configuration` が `nil` のときに直前のサーバー値を維持する既存挙動が変わらないこと。
- 公開 `Configuration` に `@unchecked Sendable` を付与していないこと。
- 公開 API のシグネチャが変更されていないこと。
- signaling message と WebRTC 設定の値と解釈が維持されること (変わるのは数値の表記と、`dataChannels` が非 nil のときの connect message に載る `Decimal` が現行の壊れた値から利用者入力どおりになる点である。connect message と `dataChannels` の `Float` / `Double` は指数表記が展開・丸めされることがあり (`-0.0` は符号が失われる)、`dataChannels` が非 nil のときは connect message の `Double` の 17 桁表記が `JSONEncoder` の表記に揃う。表記の違いは値として同一)。`Decimal` は Double の精度で表現できない値も含めて metadata 経路と `dataChannels` 経路の両方で利用者入力どおりの値と精度で出力されること。`dataChannels` の値自身は Double としての解釈が現行と同一で出力されること (表記は変わり得る)。object のキー順は不定になり (`Dictionary` の順序) 宣言順とは一致しないが、JSON として等価であること。
- `CHANGES.md` の `## develop` の主リストに、refactor の `[UPDATE]` と、`dataChannels` が非 nil のときの connect message に載る `Decimal` の修正の `[FIX]` を追記していること (本文の内容は「互換性」を参照)。`0158` が追加する `[FIX]` 2 件とは別のエントリにする。
- `Sora` と `SoraTests` が `SWIFT_VERSION=6` と `SWIFT_STRICT_CONCURRENCY=complete` でビルドでき、変更前後で concurrency 診断の件数が増えていないこと。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法

接続開始時に利用者の `Configuration` を internal な `ConnectionConfigurationSnapshot` へ写し取り、接続開始後の非同期区間が `Configuration` の参照型フィールドを読まない構造にした。signaling JSON と WebRTC 設定の値と解釈は維持し、変わるのは数値の表記と `dataChannels` が非 nil のときの connect message に載る `Decimal` の値だけである (どちらも `CHANGES.md` に記録した)。

### 実装内容

- `Sora/JSONValue.swift` (新規): `null` / `bool` / `decimal` / `double` / `string` / `array` / `object` を持つ internal な `JSONValue` と、`Encodable` / `Any` からの変換 (`from(_:errorReason:)` / `fromDataChannels(_:errorReason:)`)。`Encodable` は `JSONValueBox` で keyed container へ入れてから encode し、`SignalingConnect.encode(to:)` の `superEncoder` と同じ結果にする。`dataChannels` は `JSONSerialization.isValidJSONObject` → `data(withJSONObject:)` → `JSONDecoder` で変換する。
- `Sora/ConnectionConfigurationSnapshot.swift` (新規): `ICEServerSnapshot` / `WebRTCConfigurationSnapshot` / `ForwardingFilterSnapshot` / `ConnectionConfigurationSnapshot`。stored property はすべて `let` で、`@unchecked Sendable` は使っていない。`RTCConfiguration` / `RTCMediaConstraints` は Objective-C の class のため computed property (`nativeValue` / `nativeConstraints`) として生成する。検証の理由文字列は `ConfigurationSnapshotErrorReason` に集約した。
- `Sora/Configuration.swift`: `parsePEMCertificates(_:)` を internal に変更した。`parsedCACertificates()` は既存テスト互換のラッパーとして残している。
- `Sora/ICEServerInfo.swift` / `Sora/WebRTCConfiguration.swift` / `Sora/TLSSecurityPolicy.swift`: snapshot へ移設した `nativeValue` / `nativeConstraints` / `usesVerifiedTURNTLS` を削除し、重複実装を残さない。`TLSSecurityPolicy.nativeValue` と private テーブルは参照元が無くなったため削除した。
- `Sora/NativePeerChannelFactory.swift`: `createNativePeerChannel` / `createClientOfferSDP` / `createCertificateVerifier` の引数を `webRTCConfiguration: WebRTCConfigurationSnapshot` に変更し、`constraints:` 引数を削除して snapshot の `nativeConstraints` を使う。
- `Sora/Signaling.swift`: internal な `dataChannelSettings` を追加し、`SignalingConnect.encode(to:)` が `data_channels` を出力する。
- `Sora/SignalingChannel.swift`: snapshot と handler bag を受け取る init に変更し、`configuration` を削除した。`send` の `JSONSerialization` マージを削除した。
- `Sora/PeerChannel.swift`: 利用者由来 snapshot を保持し、接続所有の `webRTCConfiguration` を `webRTCConfigurationLock` 配下で読み書きする。offer 受信時の更新は `replacing(...)` で新しい値を作る。`makeSignalingConnect` と接続処理の参照を snapshot へ移した。
- `Sora/MediaChannel.swift`: designated init を `init(snapshot:configuration:audioDevice:mediaChannelHandlers:webSocketChannelHandlers:...)` とし、`validate(snapshot:)` へ変更した。`precondition(snapshot.usesCustomAudioDevice == (audioDevice != nil))` で内部不変条件を表明する。
- `Sora/Sora.swift`: snapshot 生成を `MediaChannel.init` より先に行い、失敗を既存の設定エラー経路で通知する (ADM / WebSocket / `RTCPeerConnection` を生成しない)。
- `SoraTests/ConnectionConfigurationSnapshotTests.swift` (新規): 変換の単体テスト、値の凍結、connect JSON のゴールデン、旧経路との等価比較、codec 別 params の条件、`CameraSettings` の凍結、TURN-TLS ポリシー。
- `SoraTests/ConnectConfigurationValidationTests.swift` (新規): `0158` の検証テストを snapshot 生成経由へ移行したもの。
- 既存テスト: `PeerChannel` / `SignalingChannel` の新しい init と `MediaChannel.validate(snapshot:)` へ移行し、`SendableConformanceTests` に snapshot 4 型の表明を追加した。
- `CHANGES.md`: `## develop` の主リストへ `[UPDATE]` と `[FIX]` を追記した。

### 設計上の判断

- `MediaChannel` は snapshot を stored property として保持しない。接続開始後の読み出しを `PeerChannel` / `SignalingChannel` が自身の snapshot から行う形にしたため、保持しても読まれない。`MediaChannel.configuration` の doc に、参照型フィールドを読まないことと、値型フィールドを読む箇所 (公開 getter / `description` / 公開 mute API / `senderStream` / `receiverStreams`) を列挙した。
- `PeerChannel.init` の `required` はサブクラスが存在しないため削除した。
- `WebRTCConfiguration.isInsecure` は書き込み元が消えて常に false になったため削除し、snapshot 生成では `false` 固定とした。一時 offer の生成に `Configuration.insecure` を反映しない既存挙動を保つためである (offer 受信時に `Configuration.insecure` で置き換わる)。
- `MediaChannel.connect` の未使用な `timeout` 引数は呼び出し元が無いため削除した。`webRTCConfiguration` は既存テストの呼び出し互換のため残し、doc に「接続処理では使わない」と明記した (公開引数としての扱いは `0153`)。
- `JSONValue` は `Int64` / `UInt64` の case を持たない。`Decimal` を `Double` より先に判定するため整数トークンも `Decimal` として読まれ、この 2 case は到達不能である (その旨を doc に書いた)。
- `initializeSenderStream` は接続所有の WebRTC 設定を 1 回だけ読み、constraints と `degradationPreference` の両方に使う。`createAndSendAnswer` は更新後の値を再読せず、ローカルの値で `createNativePeerChannel` / `setConfiguration` / `createAnswer` を作る。
- `NativePeerChannelFactory` の引数名は `webRTCConfiguration:` に統一した。`snapshot:` は `PeerChannel` の利用者設定全体を指す `snapshot` と衝突するため採らない。
- `0158` の検証は `ConnectionConfigurationSnapshot.init` へ移設した。`0158` の設計方針が置き場所としていた `MediaChannel.validate(configuration:)` ではなく snapshot 生成に置いたのは、同じ変換を 2 回行わないためである。`0158` は本 issue に統合して完了とした。
- ソースコードのコメントに issue 番号を書かない。将来の対応は理由そのものを書く。
- `MediaChannel.validate(snapshot:)` の audio 制約の理由文字列は既存のままとした。

### 検証

- `swiftc -typecheck -swift-version 6` (`Sora/` 全体、iPhoneOS 26.5 SDK / Xcode 26.6): 0 error。warning は 57 件 (実装直後は 60 件で、未参照になった `TLSSecurityPolicy.nativeValue` と private テーブルの削除により 3 件減った)。
- `swift format lint --strict`: 通過。
- `xcodebuild build-for-testing` / `test-without-building` (iPhone 17 Pro / iOS 26.5、`SWIFT_VERSION=6`、E2E を除く): 231 件が成功 (失敗 0)。`ConnectionConfigurationSnapshotTests` の 22 件と `ConnectConfigurationValidationTests` の 6 件を含む。
- `#SendableClosureCaptures` は実装の前後で 67 → 67 で増えていない (実装時の計測)。
- 接続試行のタイムアウトが `Configuration.connectionTimeout` から `ConnectionTimer` へ渡ることを既存テストの成功で確認した。
- Thread Sanitizer を有効にした非 E2E テスト (`xcodebuild test -enableThreadSanitizer YES`) を実行した。`PeerChannel.onConnect` の data race (`invokeConnectHandler` の書き込みと `state` getter の読み込み) が検出され、サニタイザがテストプロセスを終了させたためスイートは完走しなかった。競合している箇所 (`onConnect` / `state` / `finishBasicDisconnect` / `invokeConnectHandler`) は本 issue が変更しておらず (develop と同一)、既存の問題として `0151` (PeerChannel.onConnect のデータ競合) が扱う。本 issue の変更範囲 (snapshot の写し取りと参照先の置き換え) では race は検出されていないが、最初のレポートで実行が終了したため全経路の走査は完了していない。
- 元の metadata object / `ICEServerInfo` を別スレッドから変更する probe は実施していない。snapshot の生成は接続開始の同期区間で行い、生成後に SDK が元の object を読まないことは凍結テストと connect JSON のゴールデンで確認している。
- E2E テスト (実 Sora) と CI (Xcode 26.2 / iPhoneOS 26.2 SDK) は未実施。push 後に `ci.yml` の E2E と `build.yml` の Release build で確認する。

### 実機確認

不要と判断した。変更は接続開始時の値の写し取りと設定の参照先の置き換えで、実行される通信・音声・カメラの処理自体は変えていない。最終的な確認は実 Sora に対する E2E テストで行う。
