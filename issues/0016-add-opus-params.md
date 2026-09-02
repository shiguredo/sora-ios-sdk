# type: connect の audio.opus_params に対応する

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-opus-params
- Polished: 2026-09-02

## 目的

`Configuration` に Opus 固有のパラメーター `opus_params` を指定できるようにし、`type: connect` シグナリングメッセージの `audio.opus_params` として送信できるようにする。`opus_params` には `channels` / `maxplaybackrate` / `maxaveragebitrate` / `minptime` / `ptime` / `stereo` / `sprop_stereo` / `useinbandfec` / `usedtx` といった Opus 固有のパラメーターが含まれ、ステレオ送信や FEC / DTX などの細かい音声設定をユーザーが制御できるようになる（Sora のシグナリングの型定義の `OpusParams` に基づく）。

## 優先度根拠

- 既存機能の不具合ではなく利便性向上を目的とした機能追加であり、緊急性は低い。
- Opus の細かい音声設定を制御できるようにする補助的な機能のため Low とする。

## 現状

`Configuration` から送信できる音声設定は `audioCodec` と `audioBitRate` に限られており、`opus_params` を送信する経路が存在しない。`SignalingConnect`（`Sora/Signaling.swift` の `SignalingConnect` 構造体）も音声については `audioCodec` / `audioBitRate` のみを保持する。

`encode(to:)` の `audio` コンテナ生成条件（`Sora/Signaling.swift` の `SignalingConnect.encode(to:)`）は以下のとおりであり、`opus_params` のみを指定した場合に `audio` コンテナが生成されない:

```swift
if audioCodec != .default || audioBitRate != nil {
```

`AudioCodingKeys`（`Sora/Signaling.swift` の `SignalingConnect.AudioCodingKeys`）には `codec_type` と `bit_rate` しかなく、`opus_params` のキーが存在しない。映像コーデックパラメーター（`vp9Params` / `av1Params` / `h264Params` / `h265Params`）は `Encodable?` として `SignalingConnect` → `Sora/PeerChannel.swift` の `makeSignalingConnect` で渡され、`encode(to:)` では `superEncoder` パターンでネストしたコンテナにエンコードされている。音声側も同様のパターンで実装できる。

## 設計方針

映像コーデックパラメーター（`videoVp9Params` 等）と同じ設計に揃え、`opus_params` を `Encodable?` として透過的に渡す。SDK 側で個別パラメーターの型を厳密に持たないため、サーバーの仕様変更にも追従しやすい。新規プロパティのデフォルトは `nil` とし、後方互換性を維持する。

変更が必要な箇所は以下の 3 ファイルにわたる:

1. **`Sora/Configuration.swift`**: `audioBitRate` プロパティの直後に `audioOpusParams: Encodable?` を追加する。`Configuration` の命名規則は `video` プレフィックス付きの `videoVp9Params` / `videoAv1Params` / `videoH264Params` / `videoH265Params` に対応して、音声は `audio` プレフィックス付きの `audioOpusParams` とする。デフォルト `nil`。

2. **`Sora/Signaling.swift`**:
   - `SignalingConnect` 構造体の `audioBitRate` プロパティの直後に `public var opusParams: Encodable?` を追加する（`SignalingConnect` 側は `vp9Params` / `av1Params` / `h264Params` / `h265Params` と同様にプレフィックスなし）。
   - `AudioCodingKeys` に `case opus_params` を追加する。
   - `audio` コンテナ生成条件を `if audioCodec != .default || audioBitRate != nil || opusParams != nil {` に変更する。
   - `encode(to:)` の `audio` コンテナ内で `audioBitRate` の `encodeIfPresent` 直後に、映像コーデックパラメーターと同様の `superEncoder` パターンで `opusParams` のエンコード処理を追加する。送信条件は後述の「opus_params の送信条件」に従う。

3. **`Sora/PeerChannel.swift`**: `makeSignalingConnect` の `SignalingConnect(...)` メンバーワイズイニシャライザ呼び出しの引数リストに、`h265Params: configuration.videoH265Params` の直後に `opusParams:` を追加する。値は後述の「opus_params の送信条件」に従って絞り込む。これはプロパティ代入ではなくイニシャライザの引数追加である。この変更がなければ `Configuration.audioOpusParams` の値がシグナリングメッセージに反映されない。

### opus_params の送信条件

`opus_params` は Opus 固有のパラメーターのため、`audioCodec` が `.opus` または `.default` の場合のみ送信し、`.pcmu` の場合は送信しない。映像側（0011 / 0074）と同じ二重防御とし、`PeerChannel` での絞り込みに加えて `encode(to:)` 側でもガードする。

```swift
// Sora/PeerChannel.swift の makeSignalingConnect
opusParams:
  (configuration.audioCodec == .opus || configuration.audioCodec == .default)
  ? configuration.audioOpusParams : nil,
```

```swift
// Sora/Signaling.swift の SignalingConnect.encode(to:) 内
if let opusParams, audioCodec == .opus || audioCodec == .default {
  let opusParamsEnc = audioContainer.superEncoder(forKey: .opus_params)
  try opusParams.encode(to: opusParamsEnc)
}
```

`.pcmu` のときに `opus_params` を送ると `codec_type: PCMU` と Opus 固有パラメーターの不整合な組み合わせになり、Sora サーバーに拒否されるためである。

なお、音声の `.default` は Opus を意味する（`Sora/AudioCodec.swift` の `AudioCodec.default` のドキュメント）。映像側の `.default` はどのコーデックとも整合しないため params を送らない（0074）が、音声側は `.default` でも `opus_params` を送る点に注意する。また、`opus_params` は映像の `vp9_params` 等と違い、sora.conf での有効化設定を必要としない（Sora のシグナリングの型定義で `audio.opus_params` にそのような注記はない）。

### audioEnabled = false の場合

`audioEnabled = false` の場合、`encode(to:)` は `audio` コンテナを生成せず `false` を送信する既存の挙動があり、`opusParams` を指定していても無視される。これは意図した動作として許容する。

### audioOpusParams のみ指定した場合

`audioOpusParams` のみ指定して `audioCodec` と `audioBitRate` を両方デフォルトのままにした場合、`audio` コンテナは `{"opus_params": {...}}` となり `codec_type` キーを含まない。Sora サーバーはこれを音声有効として処理できることを前提とする（Sora のシグナリングの型定義では音声コーデック種別は `OPUS` のみであり、`codec_type` 省略時は Opus がデフォルトコーデックとなる）。

## テスト方針

モック・スタブは使用しない。シグナリングメッセージの JSON エンコードは `JSONEncoder` を使った純粋なユニットテストで検証できる。

以下をテストする:

- `audioOpusParams` が `nil` の場合、`SignalingConnect` のエンコード結果の JSON に `audio.opus_params` キーが存在しないこと。
- `audioOpusParams` に具体的な `Encodable` 型（テスト専用の `struct TestOpusParams: Encodable { let minptime: Int }` 等）を設定した場合、`audio.opus_params` がエンコードされること。`opusParams: Encodable?` は型消去のため `JSONEncoder().encode(opusParams!)` を直接呼べないが、`SignalingConnect` 全体を `JSONEncoder` でエンコードすることで検証できる。
- `audioCodec` / `audioBitRate` を両方デフォルト値に保ち `audioOpusParams` のみ設定した場合、`audio` コンテナが生成されること（生成条件拡張の確認）。
- `audioCodec` が `.pcmu` の場合、`audioOpusParams` を設定しても `audio.opus_params` が JSON に含まれないこと（コーデック一致ガードの確認）。
- `audioEnabled = false` の場合、`audioOpusParams` を設定しても `audio` コンテナが生成されずキーが存在しないこと。

テストの追加先は新規ファイル `SoraTests/SignalingConnectTests.swift` を作成すること。`SoraTests/` 配下に `SignalingConnect` のエンコードを直接検証するテストファイルは存在しない。なお `SoraTests/PeerChannelConnectEncodingTests.swift` が `makeSignalingConnect` 経由で同じエンコード経路を検証しているため、既存のテストと重複しない範囲で構成する。

## 完了条件

- `Configuration` に `audioOpusParams: Encodable?` プロパティが追加されること。
- `SignalingConnect` に `opusParams: Encodable?` プロパティが追加されること。
- `AudioCodingKeys` に `case opus_params` が追加されること。
- `audio` コンテナ生成条件が `opusParams != nil` を含む形に拡張されること。
- `PeerChannel.swift` の `SignalingConnect(...)` イニシャライザ引数リストに `opusParams:` が追加されること（`h265Params: configuration.videoH265Params` の直後）。
- `audioCodec` が `.opus` / `.default` の場合のみ `audio.opus_params` が送信され、`.pcmu` の場合は送信されないこと。
- `audioOpusParams` が `nil` の場合は `opus_params` がエンコードされず既存の挙動が変更されないこと（後方互換）。
- テスト方針に記載したテストがすべて通ること。
- `CHANGES.md` の `develop` セクションに以下の形式で追記すること:

```
- [ADD] `Configuration.audioOpusParams` を追加して audio.opus_params を指定できるようにする
  - @voluntas
```

## 解決方法
