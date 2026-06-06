# RTCRtpCodecCapability をログに出力する機能を追加する

- Priority: Low
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/add-rtcrtpcodeccapability-log
- Polished: 2026-06-06

## 目的

接続時に端末で利用可能な RTP コーデック情報（`RTCRtpCodecCapability`）を DEBUG レベルのログとして出力する。コーデック関連のバグ調査時に「この端末で何のコーデックが使えるか（音声・映像の送受信別）」を即座に把握できるようにする。

## 優先度根拠

コーデック関連バグ（0039: サイマルキャスト複数コーデッククラッシュ）の調査において、端末の RTP コーデックサポート状況が分かると切り分けが容易になる。ただし必須の修正ではなくデバッグ補助的な追加機能であるため Low とする。

## 現状

### 既存のコーデックログ

`NativePeerChannelFactory.init()` では `encoder.supportedCodecs()` および `decoder.supportedCodecs()` によって映像エンコーダー・デコーダーがサポートするコーデック（`RTCVideoCodecInfo`）を DEBUG ログに出力している。ただしこれは映像のみであり、音声コーデックは含まれない。また「WebRTC エンジンのコーデックエンコード能力」と「RTP ネゴシエーションで使える能力（`RTCRtpCodecCapability`）」は異なる概念である。

### 不足している情報

接続ごとに `RTCPeerConnectionFactory.rtpSenderCapabilitiesForKind:` / `rtpReceiverCapabilitiesForKind:` で取得できる「RTP コーデック能力」は音声・映像の送受信別のコーデック情報を含むが、現在これを確認するログが存在しない。

## 設計方針

`PeerChannel.connect()` の冒頭、`lock.lock()` の直前（`PeerChannel.swift` の `"try connecting"` ログ行と `lock.lock()` の間にあるコメント行の後）に以下を追加する。`PeerChannel` は `nativePeerChannelFactory` プロパティ（`NativePeerChannelFactory` 型）を持つため、そこから `nativeFactory`（`RTCPeerConnectionFactory`）にアクセスできる。`rtpSenderCapabilities(forKind:)` は `RTCPeerConnectionFactory` のインスタンスメソッドであり、`RTCPeerConnection` インスタンスを必要としないためロック取得前でも安全に呼べる。

`forKind:` の引数に `"audio"` / `"video"` というリテラルを用いる（`kRTCMediaStreamTrackKindAudio` / `kRTCMediaStreamTrackKindVideo` という定数と等価であり、リテラルで呼び出しても動作は変わらない）。

```swift
let audioSendCodecs = nativePeerChannelFactory.nativeFactory.rtpSenderCapabilities(forKind: "audio").codecs
Logger.debug(
    type: .peerChannel,
    message: "audio send codec capabilities: \(audioSendCodecs.map { "\($0.mimeType)/\($0.clockRate?.intValue ?? 0)" }.joined(separator: ", "))"
)
let audioRecvCodecs = nativePeerChannelFactory.nativeFactory.rtpReceiverCapabilities(forKind: "audio").codecs
Logger.debug(
    type: .peerChannel,
    message: "audio receive codec capabilities: \(audioRecvCodecs.map { "\($0.mimeType)/\($0.clockRate?.intValue ?? 0)" }.joined(separator: ", "))"
)
let videoSendCodecs = nativePeerChannelFactory.nativeFactory.rtpSenderCapabilities(forKind: "video").codecs
Logger.debug(
    type: .peerChannel,
    message: "video send codec capabilities: \(videoSendCodecs.map { "\($0.mimeType)/\($0.clockRate?.intValue ?? 0)" }.joined(separator: ", "))"
)
let videoRecvCodecs = nativePeerChannelFactory.nativeFactory.rtpReceiverCapabilities(forKind: "video").codecs
Logger.debug(
    type: .peerChannel,
    message: "video receive codec capabilities: \(videoRecvCodecs.map { "\($0.mimeType)/\($0.clockRate?.intValue ?? 0)" }.joined(separator: ", "))"
)
```

- `RTCPeerConnectionFactory` のメソッド名は `rtpSenderCapabilities(forKind:)` / `rtpReceiverCapabilities(forKind:)`（Swift での呼び名。Obj-C では `rtpSenderCapabilitiesForKind:` / `rtpReceiverCapabilitiesForKind:`）
- `RTCRtpCodecCapability.mimeType` は `"audio/opus"` や `"video/H264"` という `kind/name` 形式の文字列
- `RTCRtpCodecCapability.clockRate` は `NSNumber?`（nullable）のため `?.intValue ?? 0` でアンラップする
- 出力例: `"audio send codec capabilities: audio/opus/48000, audio/PCMU/8000, ..."`
- ログメッセージは英語で書くこと（CLAUDE.md の規約）

## 完了条件

- `PeerChannel.connect()` 実行時に音声・映像の送受信コーデック能力リストが 4 行の DEBUG ログとして出力されること
- ログ形式が `"audio send codec capabilities: audio/opus/48000, ..."` の形式で出力されること（`mimeType` と `clockRate` が `/` で結合されたカンマ区切りリスト）
- ログメッセージが英語で書かれていること
- `CHANGES.md` の `## develop` セクションにある既存の `[ADD]` エントリの最後に以下を追記すること

```
- [ADD] 接続時に RTCRtpCodecCapability の一覧を DEBUG ログとして出力するようにする
  - @voluntas
```
