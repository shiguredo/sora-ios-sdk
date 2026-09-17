# videoEnabled / audioEnabled の変更を operation 単位で直列化する

- Created: 2026-09-17
- Completed:
- Priority: Medium
- Branch: feature/fix-video-enabled-flag-serialization
- Polished:

## 目的

同一 `MediaStream` の `videoEnabled` / `audioEnabled` を複数の公開 API から並行に変更したときに、最後に確定した operation の値が最終値になり、失敗時の復元書き込みが後続の operation の値を上書きしないようにする。

`0136` が限定変更として残した「`setVideoSoftMute` と `MediaStream.videoEnabled` への直接代入との排他」を解消し、失敗時の復元を operation の一部として確定させる。音声・映像の出力可否という利用者が観測する状態の一貫性を保証することが目的であり、frame の処理順序や executor の設計は対象にしない。

## 現状

`MediaStream.videoEnabled` / `audioEnabled` は同期 `get set` の protocol requirement であり、`BasicMediaStream` の setter は「現在値と異なる場合だけ `nativeVideoTrack` / `nativeAudioTrack` の `isEnabled` を書き換え、`MediaStreamHandlers.onSwitchVideo` / `onSwitchAudio` と `videoRenderer` の `onSwitch` を呼ぶ」。getter は native track の `isEnabled` をそのまま読む。

同じ stream の `videoEnabled` / `audioEnabled` へ書き込む公開 API は次のとおりで、実行される executor が揃っていない。

- `MediaChannel.setVideoSoftMute(_:)` (`Sora/MediaChannel.swift`): 同期 API。`senderStream.videoEnabled` を呼び出し側の executor で書く
- `MediaChannel.setAudioSoftMute(_:)` (`Sora/MediaChannel.swift`): 同期 API。`senderStream.audioEnabled` を呼び出し側の executor で書く
- `MediaChannel.setVideoHardMute(_:)` (`Sora/MediaChannel.swift`): `async throws`。`mute == true` の設定と失敗時の復元は `VideoHardMuteActor.setMute` (`Sora/VideoMute.swift`) の中で行い (`0136`)、`mute == false` の成功後の書き込みは呼び出し側の executor で行う
- 利用者による `MediaStream.videoEnabled` / `audioEnabled` への直接代入

`MediaChannel.setVideoHardMute` の doc は「復元する値はこの操作が実行を開始した時点の値であり、並行する `setVideoSoftMute` や `MediaStream.videoEnabled` への直接代入とは排他されません」と明記しており、`0136` もスコープ外で「`setVideoSoftMute` と `MediaStream.videoEnabled` への直接代入は `VideoHardMuteActor` で直列化されない」「`mute = false` 側の直列化は対象外」として、この競合を扱っていない。委譲先の issue も示されていないため、本 issue がこの範囲を受け持つ。

そのため、`setVideoHardMute(true)` が失敗して復元する間に `setVideoSoftMute` が成功していても、復元の書き込みが後から上書きし得る。setter の「現在値の読み取り」と「書き込み」の間にも同期が無く、2 つの呼び出しが同時に「値が変わった」と判定して callback が二重に発火し得る。

`setVideoHardMute` 系の操作相互の排他は `VideoHardMuteOperationTracker` (`Sora/VideoMute.swift`) が同一 lease の同時実行を拒否する形で実現しているが、`setVideoSoftMute` / 直接代入との排他は無い。

## 設計方針

- 直列化の単位は「公開 API の呼び出し 1 回」を 1 operation とし、operation の順序は stream ごとの単一の線形順で確定する。書き込み 1 回ではなく operation を単位とするのは、`setVideoHardMute(true)` の設定と失敗時の復元を同じ operation に含めるためである。
- operation の識別に世代 (`operationGeneration`) を使う。stream ごとの lock 付き storage が世代と確定値を保持し、operation は開始時に世代を取得する。書き込みと復元は「自分の世代が最新である場合だけ」確定する (compare-and-set)。後続の operation が開始していた場合は、前の operation の復元を破棄して後続の値を保つ。
- `videoEnabled` / `audioEnabled` の実体値を SDK 側の lock 付き storage に持つ。getter は storage の値を返し、native track への `isEnabled` の反映は operation の確定時に行う。同期 API は現在どおり「呼び出しが戻った時点で値が確定している」契約を維持する。
- `await` をまたぐ `setVideoHardMute(true)` は、カメラ停止の待機中に他の operation が確定しても、復元の書き込みを自分の世代で判定して破棄する。operation の実行中に他の operation を拒否するのではなく、確定値を世代で調停する方式とし、同期 API の呼び出しを待たせない。
- `MediaStreamHandlers.onSwitchVideo` / `onSwitchAudio` と `videoRenderer` の `onSwitch` は、値が実際に変化した operation の executor で 1 回だけ呼ぶ。`0136` が確定した「`setVideoHardMute(true)` の経路では `VideoHardMuteActor` の executor で発火する」という契約と、復元時の発火回数・順序を維持する。
- frame の ingress executor は `0105` が扱う。本 issue は frame の順序や `VideoFilter` の実行を変更しない。
- `MediaStream` の公開 protocol と `videoEnabled` / `audioEnabled` の同期 setter は変更しない。

## 完了条件

- 同一 stream の `videoEnabled` を `setVideoSoftMute` / `setVideoHardMute` / 直接代入から並行に変更しても、線形順で最後に確定した operation の値が `videoEnabled` の getter と native track の `isEnabled` の両方で最終値になること。
- `setVideoHardMute(true)` の失敗時に、後続の operation が既に確定している場合は復元の書き込みが後続の値を上書きせず、後続の operation が無い場合は呼び出し前の値へ復元されること。
- 値が変化しない operation では `onSwitchVideo` / `onSwitchAudio` / `videoRenderer.onSwitch` が呼ばれず、変化した operation では operation ごとに 1 回だけ呼ばれること。
- `MediaChannel.setVideoHardMute` の doc の「並行する `setVideoSoftMute` や `MediaStream.videoEnabled` への直接代入とは排他されません」という記述が、保証内容に合わせて更新されていること。
- `CHANGES.md` の `## develop` に `[FIX]` の追記があること。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
