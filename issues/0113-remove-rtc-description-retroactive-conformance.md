# WebRTC enum の retroactive conformance を削除する

- Created: 2026-08-27
- Completed:
- Priority: High
- Branch: feature/remove-rtc-description-retroactive-conformance
- Polished: 2026-09-25

## 目的

imported type である WebRTC の enum 6 型を imported protocol の `CustomStringConvertible` へ retroactive conformance させている実装を削除し、SDK 内部の文字列化を SDK が所有する internal formatter へ移す。

WebRTC 側が将来同じ準拠を追加した場合の conformance 衝突を避け、SDK target を warnings-as-errors にしたときの失敗要因になる retroactive conformance warning 6 件を解消する。

削除する 6 つの `description` のうち状態系 3 型は `@unknown default` で `fatalError` を呼ぶ。置き換え後の formatter は文字列を返す関数であり、同じ switch を書き写す以上そこへ `fatalError` を書き直さない。この crash 経路の解消も本 issue に含める。

## 優先度根拠

- `0108` が SDK target の warnings-as-errors を有効化する前提として本 issue を挙げており、`0108` の着手を止めている。
- 状態系 3 型の `description` は baseline に載る公開 API で、未知の raw value を渡すとプロセスが終了する（実測）。文字列化しただけでアプリが落ちる経路を残さない。

## 前提

- `0107` は完了済み（2026-09-24）。`TestConsumers/Swift6Consumer/` の consumer package と `TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json` の公開 API baseline が利用できる。
- `0070` は Phase 0 のみを範囲とする親 issue で、`Sora/Extensions/RTC+Description.swift` の削除は未起票の Phase 3 以降が扱う。本 issue は C API 移行を待たない。
- `0108` は本 issue の完了後に SDK target の warnings-as-errors を有効化する。本 issue は `0108` を待たずに着手できる。
- `0172`（起票済み）が本 issue の `WebRTCEnumDescription` と未知 raw value の表現 `"unknown(<rawValue>)"` を前提にする。本 issue を先に完了させる。
- 実装着手前に、磨き上げ済みの本 issue と `issues/0172-bug-fix-rtc-peer-connection-state-log.md`、更新済みの `issues/SEQUENCE` が develop にコミットされていること。この 2 ファイルは本 issue の実装ブランチではなく、着手前の develop へコミットする（未追跡のままだと、変更対象に挙げた `0172` の更新ができない）。

## 現状

### retroactive conformance

`WebRTC` module の enum 6 型を `Sora` module 内で `CustomStringConvertible` に準拠させている。

| 準拠を宣言している拡張 | 未知 value の fallback |
| --- | --- |
| `Sora/Extensions/RTC+Description.swift` の `extension RTCSignalingState: CustomStringConvertible` | `fatalError("unknown state")` |
| `Sora/Extensions/RTC+Description.swift` の `extension RTCIceConnectionState: CustomStringConvertible` | `fatalError("unknown state")` |
| `Sora/Extensions/RTC+Description.swift` の `extension RTCIceGatheringState: CustomStringConvertible` | `fatalError("unknown state")` |
| `Sora/DataChannel.swift` の `extension RTCDataChannelState: CustomStringConvertible` | `"unknown"` |
| `Sora/PeerChannel.swift` の `extension RTCDegradationPreference: CustomStringConvertible` | `"-"` |
| `Sora/PeerChannel.swift` の `extension RTCPriority: CustomStringConvertible` | `"unknown(\(rawValue))"` |

### 診断

Swift 6.3.3 / Xcode 26.6 で `Sora/` を `-swift-version 6` で型検査すると、この 6 箇所に SE-0364 の retroactive conformance warning が出る（`-swift-version 5` でも出るため Swift 6.3 固有ではない）。

```
extension declares a conformance of imported type '<型>' to imported protocol 'CustomStringConvertible'; this will not behave correctly if the owners of 'WebRTC' introduce this conformance in the future
```

warning は 1 件につき診断本体の行と注釈内に子診断として再掲される行の 2 行で出るため、未修正時の `grep -c` は 12 行になる（warning は 6 件）。この診断には diagnostic group のタグ（`[#...]`）が付かず、`-Wwarning RetroactiveConformance` は `unknown warning group` になる。`0108` の `.treatWarning("DeprecatedDeclaration", as: .warning)` と同じ方法で除外できないため、コードを変更する以外に回避策がない。現在の Sora target は warnings-as-errors ではない（`Package.swift` の Sora target に `swiftSettings` はない）ため、現行 CI はこの warning のまま通過する。

### conformance を削除した場合の文字列の変化（実測）

imported な `NS_ENUM` は Swift の case 名を reflection で持たないため、準拠を削除すると文字列補間と `String(describing:)` は case 名ではなく raw 表現を返す。実 `WebRTC.xcframework` を link した iOS Simulator で実測すると 6 型すべてで既存の `description` と一致しない。

| 式 | 現在 | conformance 削除後 |
| --- | --- | --- |
| `\(RTCSignalingState.stable)` | `stable` | `RTCSignalingState(rawValue: 0)` |
| `\(RTCDataChannelState.open)` | `open` | `RTCDataChannelState(rawValue: 1)` |
| `\(RTCPriority.high)` | `high` | `RTCPriority(rawValue: 3)` |

`RTCIceConnectionState` / `RTCIceGatheringState` / `RTCDegradationPreference` も同様に raw 表現へ変わる。準拠を削除しても Swift は文字列化の欠落を検出しない（文字列補間も `String(describing:)` もコンパイルは通る）。1 箇所でも formatter へ切り替え忘れると、ログとエラー文字列の状態名が raw 表現に置き換わる。

### 未知 raw value は実行時に生成できる（実測）

imported な `NS_ENUM` の `init?(rawValue:)` は未知の raw value でも `nil` を返さず、その raw value を保持した値を作る。実 `WebRTC.xcframework` で 6 型すべてが非 nil になること（`RTCSignalingState(rawValue: 99)` など）を実測した。現行コードの `fatalError("unknown state")` は `RTCSignalingState(rawValue: 99)!.description` で再現でき、プロセスが終了する。

### `RTCDegradationPreference` の別名 case

`WebRTC.xcframework` の `RTCRtpParameters.h` は `RTCDegradationPreferenceDisabled = RTCDegradationPreferenceMaintainFramerateAndResolution`（どちらも raw value 0）と定義している。`Sora/PeerChannel.swift` の `extension RTCDegradationPreference` は `case .disabled` を `case .maintainFramerateAndResolution` より先に書いているため、値 0 では常に `"disabled"` を返し、`case .maintainFramerateAndResolution: "balanced"` は到達しない。

### 文字列化の箇所

| # | 箇所 | 現在の文字列化 |
| --- | --- | --- |
| 1 | `Sora/PeerChannel.swift` の `peerConnection(_:didChange stateChanged:)` | `"signaling state: \(stateChanged)"` |
| 2 | `Sora/PeerChannel.swift` の `peerConnection(_:didChange newState:)`（`RTCIceConnectionState` 版） | `"ICE connection state: \(newState)"` |
| 3 | `Sora/PeerChannel.swift` の `peerConnection(_:didChange newState:)`（`RTCIceGatheringState` 版） | `"ICE gathering state: \(newState)"` |
| 4 | `Sora/PeerChannel.swift` の `extension RTCRtpSender` の `updateOfferEncodings(_:)` の `networkPriority:` ログ | `"networkPriority: \(value)"` |
| 5 | `Sora/DataChannel.swift` の `BasicDataChannelDelegate.dataChannelDidChangeState(_:)` | `"\(#function): label => \(dataChannel.label), state => \(dataChannel.readyState)"` |
| 6 | `Sora/MediaChannel.swift` の `sendMessage(label:data:)` | `"readyState of the DataChannel is not open: label => \(label), readyState => \(readyState)"`（`SoraError.messagingError(reason:)` として利用者に返る） |
| 7 | `Sora/PeerChannel.swift` の `extension RTCRtpParameters` の `description` override | 内側の `String(describing: RTCDegradationPreference(rawValue: unwrapped.intValue))` と外側の `String(describing: degradationPreference)` の 2 箇所 |

6 は `readyState == .open` を弾いた後の分岐である。7 は `init?(rawValue:)` が Optional を返すため内側で `Optional(...)` が付き、外側は String に対する no-op である。実測では `-`（nil）・`Optional(disabled)`（0）・`Optional(balanced)`（3）になる。`Sora/` 内で `RTCPriority` の `description` を使うのは 4 の 1 箇所だけで、`Sora/Signaling.swift` の `SignalingOffer.Encoding` の decode は raw 文字列を switch しており `description` を使わない。テストでは `SoraTests/SignalingOfferEncodingTests.swift` の `\(expectedPriority)` と `\(priority)` が `RTCPriority` を補間している。

### 公開 API baseline

6 型の `description` は `Sora` module の公開 API として `TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json` に記録されている。`make api-check` は準拠の削除を検出して `API breakage: var <型>.description has been removed` を 6 件出して失敗し、`make api-check-fresh` は commit 済み baseline との一致を要求するため、削除と同じ commit で baseline を再生成しないと CI が失敗する。

一方、consumer package の scenario は 6 型の `description` を参照していないため、この削除を consumer package の compile で検出することはできない。削除を検出できるのは baseline の差分だけである。

## 設計方針

### 削除する準拠と formatter

- 6 型の `CustomStringConvertible` 準拠を削除する。
- `Sora/Extensions/RTC+Description.swift` に `internal enum WebRTCEnumDescription` を追加し、6 型の文字列化を状態を持たない pure function として集約する。同ファイルは `RTCSessionDescription.sdpDescription` があるため `0070` の Phase 3 まで残る。formatter は `RTC*` 型を引数に取るため Phase 3 の C API 移行で型ごと置き換わる。
- 関数は次を基本とする（`fatalError` を呼ばない）。

```swift
enum WebRTCEnumDescription {
  static func signalingState(_ value: RTCSignalingState) -> String
  static func iceConnectionState(_ value: RTCIceConnectionState) -> String
  static func iceGatheringState(_ value: RTCIceGatheringState) -> String
  static func dataChannelState(_ value: RTCDataChannelState) -> String
  static func priority(_ value: RTCPriority) -> String
  static func degradationPreference(_ value: RTCDegradationPreference) -> String
  /// `RTCRtpParameters.degradationPreference`（`NSNumber?`）用。 nil は `"-"`。
  static func degradationPreference(rawValue: Int?) -> String {
    guard let rawValue else { return "-" }
    guard let value = RTCDegradationPreference(rawValue: rawValue) else {
      return "unknown(\(rawValue))"
    }
    return degradationPreference(value)
  }
}
```

- `degradationPreference(rawValue:)` は nil を先に `guard let` で束縛する（`Int?` のまま補間すると `unknown(Optional(99))` になり、Optional を補間したという warning も出る）。2 つ目の `guard let` は `init?(rawValue:)` が Optional を返すことによるもので、未知値の表現は `degradationPreference(_:)` の `default` が返す `"unknown(<rawValue>)"` に一本化する。`!` は `.swiftlint.yml` の `force_unwrapping`（`included` に `Sora` がある）に抵触するため使わない。
- `RTCDegradationPreference` 以外の 5 型は enum の switch と `@unknown default` で実装する。`RTCDegradationPreference` だけは `.disabled` と `.maintainFramerateAndResolution` が同じ raw value のため `value.rawValue` で分岐し、値 0 を `"disabled"` に確定する（`Int` の switch なので `default` を使い、`@unknown default` は書けない）。`case .maintainFramerateAndResolution: "balanced"` の到達しない分岐は削除する。
- `@unknown default` を付けた enum の switch では、既知 case を書き忘れても warning 止まりで `@unknown default` に落ちる（`-warnings-as-errors` でのみ error。Sora target はまだ warnings-as-errors ではない）。既知 case を落とさないことは、テスト方針の `RTCDescriptionTests` が「設計方針」の表の全 case を検証することで担保する。
- 既知 case の戻り値は現行の `description` と完全に一致させる。

| 型 | raw value | 文字列 |
| --- | --- | --- |
| `RTCSignalingState` | 0-5 | `stable` / `haveLocalOffer` / `haveLocalPrAnswer` / `haveRemoteOffer` / `haveRemotePrAnswer` / `closed` |
| `RTCIceConnectionState` | 0-7 | `new` / `checking` / `connected` / `completed` / `failed` / `disconnected` / `closed` / `count` |
| `RTCIceGatheringState` | 0-2 | `new` / `gathering` / `complete` |
| `RTCDataChannelState` | 0-3 | `connecting` / `open` / `closing` / `closed` |
| `RTCDegradationPreference` | 0-3 | `disabled` / `maintain-framerate` / `maintain-resolution` / `balanced` |
| `RTCPriority` | 0-3 | `very-low` / `low` / `medium` / `high` |

- 未知 raw value の戻り値は 6 型すべて `"unknown(<rawValue>)"` に統一し、診断できるようにする。`"-"` は `RTCRtpParameters.degradationPreference` が nil（未設定）の場合だけに使う。

### 呼び出し箇所の置き換え

- 「現状」の表の 1 から 6 を formatter 経由に変更する。7 は内側と外側の `String(describing:)` を両方やめて `WebRTCEnumDescription.degradationPreference(rawValue:)` を呼ぶ。
- `Sora/MediaChannel.swift` の `sendMessage(label:data:)` の reason の組み立てを、`shouldNotifyDataChannelAvailable` と同じ形の internal な静的純関数へ切り出し、`sendMessage` からは `Self.messagingErrorReasonDataChannelNotOpen(label:readyState:)` として呼ぶ（`Self.` を付けないと `static member cannot be used on instance of type 'MediaChannel'` のコンパイルエラーになる）。全 case を検証できるよう、状態はそのまま文字列化する（`open` を渡す経路は `sendMessage` の `guard readyState == .open` により実運用では現れないが、純関数のテストでは全 case を網羅する）。

```swift
/// DataChannel が OPEN でないため sendMessage が返す error reason を組み立てます。
/// 状態を持たない純粋関数であり、単体テストの対象です。
static func messagingErrorReasonDataChannelNotOpen(
  label: String, readyState: RTCDataChannelState
) -> String {
  "readyState of the DataChannel is not open: label => \(label), readyState => \(WebRTCEnumDescription.dataChannelState(readyState))"
}
```

### 意図的に変える文字列

- 7 は `Optional(...)` を付けない `<transactionId> disabled` の形になる。`Optional` は `String(describing:)` に Optional を渡したことによる実装の副産物であり、値の表現ではない。値部分（`disabled` / `balanced` など）は変えない。
- 未知 raw value は、クラッシュしなかった `RTCDataChannelState` の `"unknown"` と `RTCDegradationPreference` の `"-"` が `"unknown(<rawValue>)"` になる。状態系 3 型の `fatalError` から `"unknown(<rawValue>)"` への変更は `[FIX]` として記録する。既知 case の文字列は変わらない。

### 互換性

- 準拠を削除する経路だけを採り、`@retroactive` を付けて準拠を残す経路は採らない。
  - `@retroactive` は「WebRTC 側が同じ準拠を追加した場合の衝突リスクを明示的に受け入れる」注釈であり、本 issue の目的である衝突回避を達成しない。
  - `0108` は `0113` にこの warning の解消を前提として求めている。`@retroactive` は診断を消すだけで衝突リスクを残す。
  - 6 型の準拠は SDK 内部のログとエラー文字列のために追加されたもので、`0107`（完了済み）は `0113` を準拠の削除と baseline 更新を行う issue として扱っている。削除後は文字列化を formatter が担うため、準拠を残す理由がない。
- 準拠の削除は source compatibility への破壊的変更である。`description` の直接利用はコンパイルエラーになり、利用者コードでの文字列補間と `String(describing:)` の出力は raw 表現に変わる（SDK 内部のログは formatter により従来どおり）。Swift では protocol conformance を非推奨化できないため非推奨期間を設けられず、`CHANGES.md` の `## develop` に `[CHANGE]` を追加して次期 release で告知する（`## develop` には `RPCErrorDetail.data` の型変更など source compatibility を壊す `[CHANGE]` が既にある）。`0115` / `0117` / `0122` が前提とする「次期 major version」は非推奨期間を置いた削除の計画であり、本 issue の扱いとは異なる。
- `MediaChannel.sendMessage(label:data:)` が返す `SoraError.messagingError(reason:)` の `readyState` 表記は利用者可視の文字列であるため、`open` / `connecting` / `closing` / `closed` のまま維持する。

### API baseline の再生成

- 削除と同じ commit で `TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json` と `iphoneos26.5.info.txt` を再生成する（`CODEBASE.md` の手順に従う。Xcode 26.6 と `iphoneos26.5` が必要）。
- 期待する差分は、`make api-check-fresh` の要約（Makefile の `API_BASELINE_DIFF`）が Removed declarations 12 件、Added declarations 0 件になること。12 件の内訳は 6 型の `description`（`[Var]`）×6 と 6 型の TypeDecl（`[Enum]`）×6 である（実測）。`description` の accessor（`Get()`）は `collect()` が `accessors` キーを辿らないため要約には現れない。`RTCPriority` も TypeDecl ごと消え、`SignalingOffer.Encoding.networkPriority` の型参照（`TypeNominal`）だけが残る。`WebRTCEnumDescription` と `MediaChannel` の純関数は internal なので baseline には現れない。これ以外の型、`printedName` / `declKind` の変化は意図しない変更として原因を特定する。
- baseline の再生成前は `make api-check` が `API breakage: var <型>.description has been removed` を 6 件出して失敗するため、`make api-check-fresh` は要約を出す前に停止する。要約の内訳を確認する場合は、`swift-api-digester -dump-sdk` の出力と commit 済み baseline を `API_BASELINE_DIFF` と同じ手順で比較する。

## スコープ外

- `RTCSessionDescription.sdpDescription` は protocol conformance ではないため削除しない（`0070` が扱う）。
- WebRTC C API への移行は `0070` で扱う。
- ログレベルとログの枠組みは変更しない（個別の文字列は本 issue の対象に含む）。
- `Sora/PeerChannel.swift` の `peerConnection(_:didChange newState:)`（`RTCPeerConnectionState` 版）は準拠を追加していない型であり、`String(describing:)` の raw 表現のまま残る。同じ raw 表現の問題だが本 issue の対象外であり、起票済みの `0172` が扱う。`0172` は本 issue の `WebRTCEnumDescription` に `peerConnectionState(_:)` を追加するため、`WebRTCEnumDescription` の名前と集約先ファイルを変えない。

## テスト方針

モックやスタブは使用しない。テストは `SoraTests` の warnings-as-errors（`0171`）の対象なので、追加・変更するテストファイルは `-swift-version 6` で警告を出さないこと（確認は `0171` の手順に委ねる）。

- `SoraTests/RTCDescriptionTests.swift`（新規、`import WebRTC` と `@testable import Sora`）で 6 型の既知 case を formatter へ入力し、「設計方針」の表と一致することを確認する。`RTCDegradationPreference` の `.disabled` と `.maintainFramerateAndResolution` は同じ値なので期待値は raw value ごとに 1 つとし、両シンボルが同じ文字列を返すことも確認する。
- 同じテストで未知 raw value を `RTCSignalingState(rawValue: 99)` の形で生成し（`init?(rawValue:)` が未知値でも非 nil を返す）、6 型すべてで `"unknown(99)"` を返し `fatalError` を呼ばないことを確認する。
- 同じテストで `RTCRtpParameters` を生成し `transactionId` を設定して、`degradationPreference` が nil で `<transactionId> -`、raw value 0 で `<transactionId> disabled`、3 で `<transactionId> balanced`、未知値で `<transactionId> unknown(99)` になり、`Optional(` と `__C.` を含まないことを確認する。
- `SoraTests/SignalingOfferEncodingTests.swift` の `testRTCPriorityDescription` を formatter を検証するテストへ変更する（準拠を削除すると `priority.description` がコンパイルできないため必須）。同じファイルの `\(expectedPriority)`（`testRtpEncodingParametersReflectsNetworkPriority`）と `\(priority)`（失敗メッセージ）も `RTCPriority` を補間しており、準拠の削除後は raw 表現になるため formatter の出力へ変更する。`SoraTests` でこの 6 型を参照するファイルはこの 1 つだけである。
- `SoraTests/DataChannelNotificationTests.swift`（`import WebRTC` を追加する）に、`MediaChannel.messagingErrorReasonDataChannelNotOpen(label:readyState:)` の戻り値を検証するテストを追加する。`sendMessage` 経由では `open` が現れないため、純関数のテストで `open` / `connecting` / `closing` / `closed` の全 case の文字列を確認する。既存の `PeerChannelRedirectInvalidationTests` は redirect 経路の `reason.contains("not open yet")` を見るだけで、`readyState` を含む reason は検証していない。
- 同じ `RTCDescriptionTests.swift` に `Logger.shared.onOutputHandler` で 1 から 5 のログを捕捉するテストを追加する。
  - `Logger.shared` の既定 level は `.info`、既定 groups は `[.channels, .user]` なので、`level = .debug` と `groups = [.channels]` を設定し、`SoraTests/LoggerTests.swift` と同じ方法で `setUp` / `tearDown` に instance と level / groups / onOutputHandler の保存と復元を書く（`LoggerTests` の収集用クラスは file private なので、同等のものを `RTCDescriptionTests.swift` に用意する）。handler は複数の executor から並行に呼ばれ得るため、収集は `NSLock` で排他する。
  - `NativePeerChannelFactory` と `PeerChannel.init(snapshot:signalingChannel:nativePeerChannelFactory:mediaChannel:)` で `PeerChannel` を生成する（`SoraTests/PeerChannelRedirectInvalidationTests.swift` と同じ形）。生成時に factory の debug ログが届くため、収集の判定は配列全体の一致ではなくメッセージ単位にし、対象の呼び出し直前に収集を clear する。`nativeChannel` への代入は不要である（1 から 5 は `nativeChannel` を参照しない）。
  - 1 から 3 は factory から生成した実 `RTCPeerConnection` を `peerConnection(_:didChange:)` へ直接渡す。期待値は `signaling state: stable` / `ICE connection state: connected` / `ICE gathering state: complete` のように状態名を含む。`RTCIceConnectionState.new` と `RTCIceGatheringState.new` は同名のため、`.new` を使う場合は型注釈を付ける。
  - 4 は factory から生成した `RTCPeerConnection` に `add(_:streamIds:)` で track（`DummyStereoAudioLoopbackTests.swift` と同じく `createNativeAudioTrack(trackId:constraints:)` などで作る）を追加して得た `RTCRtpSender` の `updateOfferEncodings(_:)` を呼ぶ（`add` の戻り値と `dataChannel(forLabel:configuration:)` は Optional なので `XCTUnwrap` する）。sender の `parameters.encodings` の rid は nil なので、`SignalingOffer.Encoding` は `rid: nil` かつ `networkPriority: .veryLow` などの非 nil で作る（`networkPriority` が nil だとログが出ない。memberwise init の引数は `active` / `rid` / `maxBitrate` / `maxFramerate` / `scaleResolutionDownBy` / `scaleResolutionDownTo` / `scalabilityMode` / `networkPriority`）。期待値は `networkPriority: very-low`。
  - 5 は `DataChannel.swift` の `BasicDataChannelDelegate` の `dataChannelDidChangeState(_:)` であり、`PeerChannel` のメソッドではない。factory から生成した `RTCPeerConnection` の `dataChannel(forLabel:configuration:)` で実 `RTCDataChannel` を作り、`BasicDataChannelDelegate` を生成して呼ぶ。交渉前の DataChannel の `readyState` は `.connecting` なので期待値は `state => connecting` になる。ログは generation の照合より前に出るため、generation が一致しなくても捕捉できる。
  - Sora サーバーを要する E2E には依存しない。
- SDK 内に formatter を通さない文字列化が残っていないことを確認する。次の 3 つのコマンドを実行する。

```
git grep -nE '\\\((stateChanged|newState|readyState|dataChannel\.readyState)\)|networkPriority: \\\(value\)' -- Sora
git grep -nE 'String\(describing:.*(stateChanged|newState|readyState|degradationPreference)' -- Sora
git grep -n 'String(describing: RTCDegradationPreference' -- Sora
```

  1 つ目と 3 つ目は 0 行であること。2 つ目は `RTCPeerConnectionState` 版の `peerConnection(_:didChange:)`（`0172` が扱う）の 1 行だけであること（2 つ目は 7 の外側しか検出しないため、内側は 3 つ目で確認する）。
- `Sora/Extensions/RTC+Description.swift` に `fatalError` が残っていないことを確認する。
- テストのコメントに、imported type へ conformance を追加しない理由を日本語で明記する。
- retroactive conformance warning の確認（採用 toolchain は Xcode 26.6 / Swift 6.3.3）。`WebRTC.xcframework` は binaryTarget のため、fresh checkout では `swift package resolve` で `.build/artifacts/` に取得してから実行する（`.build/artifacts/` の下は checkout ディレクトリ名になるため、別名で clone した場合は読み替える）。

```
swiftc -typecheck -swift-version 6 -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -target arm64-apple-ios14.0-simulator \
  -F .build/artifacts/sora-ios-sdk/WebRTC/WebRTC.xcframework/ios-arm64-simulator \
  -module-cache-path build/module-cache $(find Sora -name '*.swift')
```

  の出力に `extension declares a conformance of imported type` が 0 行であること（未修正時は 12 行）。`-warnings-as-errors` を付けると `DeprecatedDeclaration` の error で先に停止し、この確認には使えない（恒久 gate は `0108` が入れる）。
- 追加・変更したテストを実行する。シミュレータは `.github/workflows/e2e-test.yml` と同じ手順で `iPhone 17 Pro` を用意する。E2E テストは環境変数が無い場合に skip されるため、Sora サーバー無しで全件を実行できる。

```
xcodebuild test -scheme Sora-Package -derivedDataPath build \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  SWIFT_VERSION=6
```

  変更した 3 クラスだけを先に回す場合は `-only-testing:SoraTests/RTCDescriptionTests` / `-only-testing:SoraTests/SignalingOfferEncodingTests` / `-only-testing:SoraTests/DataChannelNotificationTests` を付ける。
- `make fmt-lint` が成功し、`make lint`（`swiftlint --fix .` の後の `--strict`）も成功することを確認する。`--fix` がファイルを書き換えるため、実行後に `git diff` で意図しない整形が混入していないことを確認する。
- CI と同じ 3 scheme の consumer package を build する（`make consumer-build SCHEME=ConsumerCore` / `SCHEME=ConsumerUI` / `SCHEME=ConsumerLegacy`）。
- `make api-baseline` で再生成し、`git diff --stat TestConsumers/Swift6Consumer/ApiBaseline/` と JSON 差分をレビューしたうえで、`make api-check` と `make api-check-fresh` が成功することを確認する。

## 完了条件

- 6 型の `CustomStringConvertible` 準拠が削除され、`Sora/Extensions/RTC+Description.swift` の formatter が「設計方針」の表の文字列を返すこと（`RTCDescriptionTests` で確認）。
- 未知 raw value で `fatalError` を呼ばず `"unknown(<rawValue>)"` を返し、`Sora/Extensions/RTC+Description.swift` に `fatalError` が残っていないこと。
- 「現状」の表の 1 から 7 が formatter を通っていること。1 から 5 は `Logger` 捕捉テスト、6 は 1 つ目の grep と `messagingErrorReasonDataChannelNotOpen(label:readyState:)` のテスト、7 は `RTCRtpParameters.description` のテストと 2 つ目と 3 つ目の grep で確認する。
- API baseline が同じ commit で再生成され、差分が「設計方針」の期待どおりであること。`make api-check` と `make api-check-fresh` が成功すること。
- `make fmt-lint` / `make lint` / `make consumer-build`（3 scheme）が成功すること。
- Sora サーバー無しで実行できるテストがすべて成功すること（E2E は CI の `e2e-test.yml` で確認する）。
- `CHANGES.md` の `## develop` の種別順の主リスト（`### misc` ではない）に、次のエントリが追加されていること。各エントリの最後に、2 文字インデントで `- @<実装者の GitHub ユーザー名>` の担当者行を付ける。
  - `[CHANGE]` WebRTC enum 6 型の `CustomStringConvertible` 準拠を削除する（`description` の直接利用はコンパイルエラーになり、利用者コードでの文字列補間と `String(describing:)` の出力は raw 表現に変わる）
  - `[CHANGE]` の補足: `RTCRtpParameters.description` が `Optional(...)` を付けなくなること、`RTCDataChannelState` と `RTCDegradationPreference` の未知 value の表現が `"unknown(<rawValue>)"` に変わること
  - `[FIX]` 未知の WebRTC enum 値で `description` が `fatalError` によりプロセスを終了する問題を修正する（対象は状態系 3 型 `RTCSignalingState` / `RTCIceConnectionState` / `RTCIceGatheringState`）
  - 既存の libwebrtc m154 エントリの `RTCDegradationPreference.maintainFramerateAndResolution` に対応するという bullet を削除する（対応コードは到達しない分岐だけで、利用者の挙動を変えていない）
- 本 issue の完了で前提が古くなる記述が同じ変更で更新されていること。日付付きの実測記録は書き換えない。
  - `issues/0108-update-swiftpm-language-mode.md` の `0113` を参照する 5 箇所（37 行目の open 一覧、39 行目の `0113` の bullet、53 / 64 / 85 行目の「concurrency 系」の列挙）。37 行目は `0113` を削除し、39 行目は bullet ごと削除し、53 / 64 / 85 行目は列挙から `0113` を外す（`0155` は残す。64 行目の `2026-09-25` の実測値は残す）。
  - `issues/0171-update-soratests-warnings-as-errors.md` の 48 行目（スコープ外で `Sora` target の concurrency 警告の担当として `0113` を挙げている記述）から `0113` を外す。19 行目は `2026-09-25` の実測値の内訳なので、書き換えずに注記も不要とする。
  - `issues/0070-change-migrate-to-webrtc-c-xcframework.md` の 93 行目（`Extensions/RTC+Description.swift` の型一覧と行数）、190 行目（`RTCPriority` のログ文字列表現の移行先を `WebRTCEnumDescription` とし、`RTCRtpParameters.description` の `Optional(...)` が消えることを追記）、359 行目（Phase 3 に formatter を C API の型へ置き換えることを追記）。67 行目の計測日の注記は、行数を更新する場合は併せて扱う。
  - `issues/0172-bug-fix-rtc-peer-connection-state-log.md` の 31 行目（`0113` で formatter へ移行するという現在形）と 35 行目（`0113` の完了を前提とする記述）を、完了済みとして読み替えられる形にする。

## 変更対象

- `Sora/Extensions/RTC+Description.swift`: 3 型の準拠を削除し、`WebRTCEnumDescription` を追加する
- `Sora/DataChannel.swift`: `RTCDataChannelState` の準拠を削除し、`BasicDataChannelDelegate.dataChannelDidChangeState(_:)` を formatter 経由にする
- `Sora/PeerChannel.swift`: `RTCDegradationPreference` / `RTCPriority` の準拠を削除し、`peerConnection(_:didChange:)` の 3 箇所と `updateOfferEncodings(_:)` の `networkPriority:` ログと `RTCRtpParameters.description`（内側と外側の 2 箇所）を formatter 経由にする
- `Sora/MediaChannel.swift`: `sendMessage(label:data:)` の error reason を formatter 経由にし、`messagingErrorReasonDataChannelNotOpen(label:readyState:)` を追加する
- `SoraTests/RTCDescriptionTests.swift`（新規）: formatter / `RTCRtpParameters.description` / 1 から 5 のログ捕捉の検証
- `SoraTests/SignalingOfferEncodingTests.swift`: `testRTCPriorityDescription` を formatter の検証へ変更し、`RTCPriority` を補間している 2 箇所も formatter 経由にする
- `SoraTests/DataChannelNotificationTests.swift`: `import WebRTC` を追加し、`messagingErrorReasonDataChannelNotOpen(label:readyState:)` の全 case を検証するテストを追加する
- `TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json` / `iphoneos26.5.info.txt`: 再生成する
- `CHANGES.md`: `## develop` に `[CHANGE]` と `[FIX]` を追加し、libwebrtc m154 エントリの bullet を削除する
- `issues/0108-update-swiftpm-language-mode.md` / `issues/0171-update-soratests-warnings-as-errors.md` / `issues/0070-change-migrate-to-webrtc-c-xcframework.md` / `issues/0172-bug-fix-rtc-peer-connection-state-log.md`: 完了条件に挙げた古くなる記述を更新する（`issues/0172-...md` と `issues/SEQUENCE` の追加は前提のとおり着手前の develop へコミットする）

## 解決方法
