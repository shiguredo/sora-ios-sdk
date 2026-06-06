# remoteAudioVolume のデフォルト値を見直す

- Priority: Medium
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/change-remote-audio-volume-default
- Polished: 2026-06-06

## 目的

リモートストリーム追加時に audio track の volume を最大値（10）に強制設定しているコードを修正し、WebRTC デフォルト値で動作するようにする。最大値への強制設定はクリッピングノイズの原因となるため、不要な増幅を排除する。

## 優先度根拠

最大音量への強制設定はノイズ混入という音声品質の劣化を引き起こす可能性があり、ユーザー体験に直接影響する。ただし音量を意図的に最大にしている用途では破壊的変更となるため、影響範囲の考慮が必要。Medium とする。

## 現状

### コードの実態

`PeerChannel.swift` の `peerConnection(_:didAdd stream:)` デリゲートメソッド（`PeerChannel.swift:1352`）において、リモートストリームが追加されるたびに以下を実行している。

```swift
stream.audioTracks.first?.source.volume = MediaStreamAudioVolume.max
```

`MediaStreamAudioVolume.max` は `10.0`（`MediaStream.swift:10`）。WebRTC 内部では `RTCAudioSource.volume` はゲイン倍率として扱われ、範囲は `[0, 10]`、WebRTC デフォルト値は `1.0`（原音を変化させない）。`10.0` を設定すると約 20dB の増幅が加わり、受信信号レベルが中程度以上の場合にデジタルクリッピングが発生し、ノイズ・歪みとして聴こえる。

アプリ側が `MediaStream.remoteAudioVolume` プロパティを使って任意の値に変更できるため、SDK がデフォルトで `10.0` に固定する必要はない。

### issue 0036 との依存関係

`0036-refactor-deprecated-on-add-stream.md` は同一の `PeerChannel.swift:1352` を `peerConnection(_:didAdd receiver:streams:)` へ移行するリファクタリングを行い、その完了条件（同 issue 57 行目）に「`source.volume = MediaStreamAudioVolume.max` の設定を維持すること」と明記している。

本 issue はこの前提と矛盾する。0036 が先にマージされると変更対象箇所が消え、0036 の完了条件も破れる。実装順序は **本 issue（0045）を先に実施し、0036 の完了条件を「`source.volume = MediaStreamAudioVolume.max` から変更後のデフォルト値を維持すること」へ更新してから 0036 を実施する** こと。

## 設計方針

`PeerChannel.swift:1352` の `stream.audioTracks.first?.source.volume = MediaStreamAudioVolume.max` の行を削除する。これにより、audio track の volume は WebRTC のデフォルト値（1.0）で動作する。

`MediaStreamAudioVolume.max` への戻し方はアプリ側で `mediaStream.remoteAudioVolume = MediaStreamAudioVolume.max` を設定することで可能であり、この点をリリースノートに明記する。

## 完了条件

- `PeerChannel.swift:1352` の `stream.audioTracks.first?.source.volume = MediaStreamAudioVolume.max` が削除されていること
- 接続後に `MediaStream.remoteAudioVolume` が `1.0` を返すこと（SDK が上書きしていないため WebRTC デフォルト値のままであること）
- 通常の `sendrecv` / `recvonly` 接続でリモート音声が聴こえること
- マルチストリーム接続で各ストリームの音声が正常に動作すること
- `0036-refactor-deprecated-on-add-stream.md` の完了条件内の「`audio track の source.volume = MediaStreamAudioVolume.max` の設定」という記述を「`source.volume` を明示的に設定しないこと」に更新すること
- `0036-refactor-deprecated-on-add-stream.md` の設計方針内の「`receiver.track` を `RTCAudioTrack` にキャストできる場合のみ `source.volume = MediaStreamAudioVolume.max` を設定する」という記述を削除すること
- `CHANGES.md` の `develop` セクションに以下を追記すること

```
- [CHANGE] リモートストリーム追加時の audio track volume を最大値（10）から WebRTC デフォルト値（1.0）に変更する
  - 既存の挙動（volume=10）に戻すにはアプリ側で `mediaStream.remoteAudioVolume = MediaStreamAudioVolume.max` を設定すること
  - @voluntas
```

## 解決方法
