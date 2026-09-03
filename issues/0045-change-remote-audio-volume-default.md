# remoteAudioVolume のデフォルト値を見直す

- Priority: Medium
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/change-remote-audio-volume-default
- Polished: 2026-09-03

## 目的

リモートストリーム追加時に audio track の volume を最大値（10）に強制設定しているコードを修正し、WebRTC デフォルト値で動作するようにする。最大値への強制設定はクリッピングノイズの原因となるため、不要な増幅を排除する。

## 優先度根拠

最大音量への強制設定はノイズ混入という音声品質の劣化を引き起こす可能性があり、ユーザー体験に直接影響する。ただし音量を意図的に最大にしている用途では破壊的変更となるため、影響範囲の考慮が必要。Medium とする。

## 現状

### コードの実態

`Sora/PeerChannel.swift` の `PeerChannel` が実装する `peerConnection(_:didAdd stream:)` デリゲートメソッドにおいて、リモートストリームが追加されるたびに以下を実行している。

```swift
stream.audioTracks.first?.source.volume = MediaStreamAudioVolume.max
```

`Sora/MediaStream.swift` の `MediaStreamAudioVolume.max` は `10.0`。WebRTC 内部では `RTCAudioSource.volume` はゲイン倍率として扱われ、範囲は `[0, 10]`、WebRTC デフォルト値は `1.0`（原音を変化させない）。`10.0` を設定すると約 20dB の増幅が加わり、受信信号レベルが中程度以上の場合にデジタルクリッピングが発生し、ノイズ・歪みとして聴こえる。

アプリ側が `MediaStream.remoteAudioVolume` プロパティを使って任意の値に変更できるため、SDK がデフォルトで `10.0` に固定する必要はない。

なお、`RTCAudioSource.volume` の Objective-C 側のゲッター（libwebrtc m150 の `sdk/objc/api/peerconnection/RTCAudioSource.mm`。`@synthesize volume = _volume` のみでネイティブ値と同期しない）は初期値 `0.0` を返し、ネイティブ側の初期ゲイン（`pc/audio_rtp_receiver.h` の `AudioRtpReceiver::cached_volume_`、`1.0`）とは独立している。そのため、この行を単純に削除すると実効ゲインは 1.0 でも `MediaStream.remoteAudioVolume` は `0.0` を返すことになる。

### issue 0036 との依存関係

`0036-refactor-deprecated-on-add-stream.md` は同一の `PeerChannel` の `peerConnection(_:didAdd stream:)` を `peerConnection(_:didAdd receiver:streams:)` へ移行するリファクタリングであり、その「完了条件」の「audio track の `source.volume = MediaStreamAudioVolume.max` の設定」という記述で、受信音声のボリューム設定（`stream.audioTracks.first?.source.volume = MediaStreamAudioVolume.max`）を維持することを要求している。

本 issue はこの前提と矛盾する。0036 が先にマージされると変更対象であるボリューム設定の行が消え、0036 の完了条件も破れる。実装順序は **本 issue（0045）を先に実施し、0036 の「現状」「設計方針」「完了条件」にある `MediaStreamAudioVolume.max` の記述を、変更後の値である `1.0`（WebRTC デフォルト値）へ更新してから 0036 を実施する** こと。

## 設計方針

`PeerChannel` の `peerConnection(_:didAdd stream:)` 内の `stream.audioTracks.first?.source.volume = MediaStreamAudioVolume.max` を、WebRTC デフォルト値の `1.0` を明示的に設定する形へ変更する（`MediaStreamAudioVolume` に新たな定数は追加せず、リテラル `1.0` を使い、WebRTC デフォルト値であることの日本語コメントを付ける）。これにより、audio track の実効ゲインは WebRTC のデフォルト値（1.0、原音を変化させない）で動作する。上述のとおり Objective-C 側の `RTCAudioSource.volume` のゲッターは未設定時に `0.0` を返すため、`MediaStream.remoteAudioVolume` が実際のゲイン（1.0）を返すように明示的に設定する。

`MediaStreamAudioVolume.max`（ボリューム 10）への戻し方はアプリ側で `mediaStream.remoteAudioVolume = MediaStreamAudioVolume.max` を設定することで可能であり、この点を `CHANGES.md` の `## develop` セクションに明記する。

## 完了条件

- `PeerChannel` の `peerConnection(_:didAdd stream:)` 内の `stream.audioTracks.first?.source.volume = MediaStreamAudioVolume.max` が `1.0` を明示的に設定する形に変更されていること
- 接続後に `MediaStream.remoteAudioVolume` が `1.0` を返すこと（SDK が WebRTC デフォルト値の `1.0` を明示的に設定しているため）
- 通常の `sendrecv` / `recvonly` 接続でリモート音声が聴こえること
- マルチストリーム接続で各ストリームの音声が正常に動作すること
- `0036-refactor-deprecated-on-add-stream.md` の「完了条件」の「audio track の `source.volume = MediaStreamAudioVolume.max` の設定」という記述を「audio track の `source.volume = 1.0`（WebRTC デフォルト値）の設定」に更新すること
- `0036-refactor-deprecated-on-add-stream.md` の「設計方針」の「音声ボリューム設定: `receiver.track` を `RTCAudioTrack` にキャストできる場合のみ `source.volume = MediaStreamAudioVolume.max` を設定する」の記述を「音声ボリューム設定: `receiver.track` を `RTCAudioTrack` にキャストできる場合のみ `source.volume = 1.0`（WebRTC デフォルト値）を設定する」に更新すること
- `0036-refactor-deprecated-on-add-stream.md` の「現状」の「受信音声のボリューム設定（`stream.audioTracks.first?.source.volume = MediaStreamAudioVolume.max`）」の記述を「受信音声のボリューム設定（`stream.audioTracks.first?.source.volume = 1.0`）」に更新すること
- `CHANGES.md` の `develop` セクションに以下を追記すること

```
- [CHANGE] リモートストリーム追加時の audio track volume を最大値（10）から WebRTC デフォルト値（1.0）に変更する
  - 既存の挙動（volume=10）に戻すにはアプリ側で `mediaStream.remoteAudioVolume = MediaStreamAudioVolume.max` を設定すること
  - @voluntas
```

## 解決方法
