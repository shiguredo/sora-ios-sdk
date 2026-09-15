# JSON 化できない接続設定を接続開始前に configurationError として返す

- Created: 2026-09-15
- Completed:
- Priority: Medium
- Branch: feature/fix-invalid-connect-configuration
- Polished: 2026-09-15

## 目的

`Configuration` に JSON 化できない値を設定した場合の壊れた挙動を修正する。`dataChannels` に JSON 化できない型を渡すとプロセスが abort し、metadata などの encode に失敗すると送信されないまま接続タイムアウトを待たされる。どちらも接続開始前に `SoraError.configurationError` として利用者へ返す。

## 現状

`Sora/SignalingChannel.swift` の `SignalingChannel.send(message:)` は、connect message の送信時に次の 2 つの処理を行う。

- `JSONEncoder().encode(message)` で `Signaling` を encode する。`SignalingConnect` は `signalingConnectMetadata` / `signalingConnectNotifyMetadata` / codec 別 params / `forwardingFilter` の metadata を encode するため、`NaN` / `Infinity` を含む値では `EncodingError.invalidValue` を throw する。throw は同メソッドの `catch` で `Logger.debug(type: .signalingChannel, message: "JSON encoding failed")` を出すだけで、送信もエラー通知も行われない。
- `message` が `.connect` かつ `configuration.dataChannels != nil` のとき、encode 済みの JSON を `JSONSerialization.jsonObject(with:)` で `[String: Any]` に戻し、`data_channels` を代入して `JSONSerialization.data(withJSONObject:)` で再シリアライズする。`dataChannels` に JSON 化できない値が含まれると `data(withJSONObject:)` が NSException を送出し、Swift から捕捉できないためプロセスが abort する。

`Sora/MediaChannel.swift` の `MediaChannel.validate(configuration:)` は `audioStereoOutputEnabled` の組合せ制約だけを検証しており、JSON 化可否は検証していない。`MediaChannel.init(configuration:)` はこの検証を先頭で呼び、`Sora/Sora.swift` の `Sora.connect` は `MediaChannel(configuration:)` の throw を既存の設定エラー経路で接続 handler と `Sora.handlers.onConnect` へ通知する。

### 再現手順

1. `Configuration` の `dataChannels` に `["x": Data()]` (JSON 化できない値) を設定する。
2. `Sora.connect(configuration:handler:)` を呼ぶ。

期待: 接続開始前に `SoraError.configurationError` が handler へ返る。実際: `SignalingChannel.send` の `JSONSerialization.data(withJSONObject:)` で NSException が送出され、プロセスが abort する。

metadata の場合は `signalingConnectMetadata` に `NaN` を含む `Encodable` を設定して `Sora.connect` を呼ぶ。期待: `SoraError.configurationError` が返る。実際: `SignalingChannel.send` の `catch` が `"JSON encoding failed"` をログに出すだけで、connect message が送信されないまま `ConnectionTimer` のタイムアウトを待つ。

### 実測

手元の Swift 6.3.3 (Xcode 26.6 / iPhoneOS 26.5 SDK) で確認した。

- `JSONSerialization.isValidJSONObject(["data_channels": Data()])` は false、`Date()` / `Set` / `URL` / 非 String キーの辞書 / `Double.nan` / `Double.infinity` / `Decimal.quietNaN` / 入れ子の `NaN` も false、通常の辞書と数値は true。
- `JSONSerialization.data(withJSONObject: ["data_channels": Data([0x01])])` は `NSException` で abort する。
- `JSONEncoder().encode` は `Double` / `Float` の `NaN` / `Infinity` に対して `EncodingError.invalidValue` を throw する。`Decimal.quietNaN` は throw せず `{"v":NaN}` という不正な JSON を出力し、`JSONSerialization.jsonObject(with:options: [.fragmentsAllowed])` はそれを code 3840 で拒否する。

## 設計方針

- 検証は `MediaChannel.validate(configuration:)` に追加し、audio の組合せ制約より先に評価する。順序を JSON 化可否 → audio の組合せ制約に固定するのは、`0102` が snapshot 生成 (`Sora.connect` から `MediaChannel.init` より先に呼ぶ) へ検証を移設した後も同じ優先順位にするためである。`MediaChannel.init(configuration:)` の先頭で呼ばれるため、ADM、WebSocket、`RTCPeerConnection` を生成する前に `SoraError.configurationError` で終端できる。通知は `Sora.connect` の既存の設定エラー経路をそのまま使う。
- 検証対象は `SignalingConnect.encode(to:)` が connect message に実際に encode する値に一致させる。`PeerChannel.makeSignalingConnect` の三項演算子 (codec 一致) だけを根拠にしない。`videoEnabled` / `audioEnabled` の分岐の内側でしか params は encode されないためである。
  - `signalingConnectMetadata` と `signalingConnectNotifyMetadata` が非 nil のとき、`JSONEncoder` で encode した `Data` を `JSONSerialization.jsonObject(with:options: [.fragmentsAllowed])` で読み直せること。`Decimal.quietNaN` は encode が throw せず不正な JSON を出力するため、encode の成否だけでは不十分である (実測)。
  - codec 別 params は `SignalingConnect.encode(to:)` と同じ条件でだけ検証する。`videoVp9Params` / `videoAv1Params` / `videoH264Params` / `videoH265Params` は `videoEnabled` が true かつ対応する `videoCodec` のとき、`audioOpusParams` は `audioEnabled` が true かつ `audioCodec` が `.opus` のときだけ検証する。`videoEnabled` が false の video params、`audioEnabled` が false の `audioOpusParams`、codec が一致しない params は現行どおり connect message に載らないため検証しない。ここを緩めると現行で無視されている値が新たにエラーになり、厳しくし過ぎると壊れた値が送信経路まで残る。
  - `forwardingFilter` / `forwardingFilters` の `metadata` が非 nil のとき、`ForwardingFilter` を `JSONEncoder` で encode した `Data` を同じ手順で読み直せること。
  - `dataChannels` が非 nil のとき `JSONSerialization.isValidJSONObject(["data_channels": value])` を満たすこと。現行が再シリアライズする対象は `data_channels` を代入した connect オブジェクトであるため、同じ入れ子で検証する。
- 検証は `PeerChannel.makeSignalingConnect` を呼ばず、`Configuration` だけを見て行う。`MediaChannel.validate(configuration:)` は `PeerChannel` を生成する前の static な検証であり、`PeerChannel` のインスタンスメソッドである `makeSignalingConnect` を呼べる文脈にないためである。条件が `SignalingConnect.encode(to:)` と二重になるため、`videoEnabled` / `audioEnabled` / codec 一致条件が変わったときに両者がずれないよう、テストで「載らない params に `NaN` を入れてもエラーにならない」ことを固定する。
- `dataChannels` の検証に `JSONSerialization.data(withJSONObject:)` を使わない。abort の再現経路そのものを使わず、`isValidJSONObject` で判定する (`Sora/RPC.swift` の `RPCChannel.call` が送信前に同じ関数で検証している前例に揃える)。`isValidJSONObject` と `data(withJSONObject:)` の受理条件は、`NaN` / `Infinity` / `Decimal.quietNaN` / 入れ子の `NaN` / 非 String キーの辞書 / `Date` / `Data` / `Set` / `URL` の範囲で一致することを実測で確認済みである。
- 検証のために値の往復 (encode → `JSONSerialization` → 再 encode) は行わない。値の凍結は `0102` が snapshot 生成で行う。検証の encode は接続開始時に 1 回増えるため、利用者の `Encodable` は送信時の encode と合わせて 2 回 encode される。この二重 encode は本 issue が受け入れるコストである (`0102` が完了すると snapshot 生成時の 1 回だけになる)。
- 失敗は `SoraError.configurationError(reason:)` とし、`reason` は検証項目ごとの固定文字列にする。`SoraError` は `Equatable` ではなく `reason` 文字列しか情報を持たないため、検証順序のテストは文字列で判定する。次を固定する。
  - metadata: `signaling connect metadata could not be encoded`
  - notify metadata: `signaling notify metadata could not be encoded`
  - codec 別 params: `video vp9 params could not be encoded` (av1 / h264 / h265 は codec 名を差し替える)、`audio opus params could not be encoded`
  - `ForwardingFilter` の metadata: `forwarding filter metadata could not be encoded`
  - `dataChannels`: `data channels are not JSON-serializable`
- 失敗理由の文字列に設定値そのものを含めない。`SoraError.configurationError(reason:)` の `reason` はそのまま利用者に見えるため、キー名と失敗種別だけを含める。`JSONEncoder` の `EncodingError` の説明文 (`invalidValue` は値と codingPath を含む) や利用者の `Encodable` が投げたエラーの説明文は使わず、`catch` したエラーは握って上記の固定文字列に置き換える。ログのマスクは `0156` が扱う。
- `SignalingChannel.send` の `catch` は変更しない。本 issue の検証を通った設定に由来する encode 失敗は起きなくなる。`catch` が扱う失敗は SDK 内部で組み立てた message の不整合であり、設定値の検証とは別の関心事である。

## スコープ外

- 接続開始後に利用者が参照型の `dataChannels` / metadata を変更した場合の凍結。`0102` の snapshot 化が扱う。本 issue の検証は接続開始時点の値に対するベストエフォートであり、検証後に変更されると abort とタイムアウトは再発し得る。

## 変更対象

- `Sora/MediaChannel.swift`: `validate(configuration:)` への JSON 化可否検証の追加 (audio の組合せ制約より先に評価する)
- `SoraTests/ConnectConfigurationValidationTests.swift` (新規): 検証の単体テストと `Sora.connect` 経由の通知の検証
- `CHANGES.md`

## 前提となる issue

なし。

### 本 issue を前提とする

- `0102` (接続設定を immutable な Sendable snapshot へ変換する): 本 issue が `MediaChannel.validate(configuration:)` に追加する検証を snapshot 生成へ移設する。`0158` は `0102` より番号が大きいが、`0102` からバグ修正を分離した issue のため先に完了させる。

## テスト方針

モックやスタブは使用しない。検証テストは `SoraTests/ConnectConfigurationValidationTests.swift` に置く。

- `signalingConnectMetadata` に `NaN` を含む `Encodable` を設定した `Configuration` で `MediaChannel(configuration:)` が `SoraError.configurationError` を throw し、`reason` が `signaling connect metadata could not be encoded` であることを検証する。`Decimal.quietNaN` を metadata に設定した場合も同じエラーになることを検証する。
- `dataChannels` に `Data` / `Date` / `Set` / `URL` / 非 String キーの辞書を設定した場合と、`Double.nan` / `Double.infinity` / `Decimal.quietNaN` / 入れ子の `NaN` を設定した場合に `SoraError.configurationError` を throw し、プロセスが abort しないことを検証する (`reason` は `data channels are not JSON-serializable`)。
- `videoEnabled` が false、または `videoCodec != .vp9` のときに `videoVp9Params` に `NaN` を設定しても throw しないことを検証する。`audioEnabled` が false、または `audioCodec != .opus` のときに `audioOpusParams` に `NaN` を設定しても throw しないことも検証する。現行も connect message に載せないため無視される。この検証が「connect message に載る条件」の二重管理を検出する。
- audio の組合せ制約違反と JSON 化できない `dataChannels` を同時に設定した場合に、JSON 化可否のエラーが先に返ることを `reason` 文字列で検証する (検証順序の固定)。
- `dataChannels` が JSON 化できる辞書、配列、数値、`null` の場合は throw しないことを検証する。
- `Sora.connect(configuration:handler:)` へ JSON 化できない設定を渡したとき、`ConnectionTask` が終端し、接続 handler と `Sora.handlers.onConnect` に `SoraError.configurationError` が届くことを検証する。
- 検証は `MediaChannel.validate(configuration:)` の単体テストでも直接確認する (`SoraTests/DummyAudioDeviceTests` が既存の audio 制約を同じ形で検証している)。
- 既存テストと追加テストがすべて成功することを確認する。

## 完了条件

- 接続開始時点の `Configuration` について、JSON 化できない `dataChannels` を設定してもプロセスが abort せず、接続開始前に `SoraError.configurationError` が返ること。
- 接続開始時点の `Configuration` について、metadata、notify metadata、codec 別 params、`forwardingFilter` / `forwardingFilters` の metadata の encode 失敗が、送信されないまま接続タイムアウトを待つ状態にならず、接続開始前に `SoraError.configurationError` として返ること (`Decimal.quietNaN` のように `JSONEncoder` が throw しない値も、出力の再パースで検出されること)。
- ADM、WebSocket、`RTCPeerConnection` が生成されていないこと。
- 正しい設定に対する connect message と WebRTC 設定が変わらないこと。
- `SignalingConnect.encode(to:)` で connect message に載らない params が現行どおり無視されること。
- JSON 化可否の検証が audio の組合せ制約より先に評価されること。
- `CHANGES.md` の `## develop` の主リストに `[FIX]` を 2 件追記していること。利用者から見た症状が「プロセス abort」と「無送信のままタイムアウト」の 2 つで独立しているため 2 件とする。担当者行は `- @t-miya` とする。
- 手元の Swift 6.3.3 (Xcode 26.6) に加え、CI (`ci.yml` の self-hosted、`iphoneos26.5` SDK) でも検証結果が同じであることを確認していること。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
