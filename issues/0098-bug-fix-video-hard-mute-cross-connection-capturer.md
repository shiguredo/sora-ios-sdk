# VideoHardMuteActor が別接続の capturer を再開する問題を修正する

- Created: 2026-08-27
- Completed:
- Branch: feature/fix-video-hard-mute-cross-connection-capturer
- Polished: 2026-08-28

## 目的

複数の `MediaChannel` が存在するときに、ある接続のハードミュートで停止した `CameraVideoCapturer` を、別の接続のミュート解除処理が自身の `MediaStream` へ付け替えて再開できる問題を修正する。

カメラ停止・再開の所有権を接続へ紐付け、別接続からの操作で capturer と stream の対応が変わらないことを保証する。

## 現状

`Sora/MediaChannel.swift` の `videoHardMuteActor` は `static let` であり、すべての `MediaChannel` から共有される。

`Sora/VideoMute.swift` の `VideoHardMuteActor` は、ハードミュートで停止した capturer を `storedCapturer` へ 1 個だけ保存する。保存状態には、次の識別情報がない。

- `MediaChannel` の identity
- 論理的な接続試行 ID
- capturer を停止した sender stream の identity
- stop / restart 操作の generation

ミュート解除では `storedCapturer` を取り出し、引数で渡された `senderStream` を設定してから restart する。

このため、接続 A が停止して保存した capturer を、接続 B の `setVideoHardMute(false)` が B の sender stream へ付け替えて再開できる。

また、`VideoHardMuteActor` は `await` を含むため、actor が呼び出しを直列化していても、stop や restart の待機中に別操作が再入する可能性がある。`isProcessing` は全接続を一律に拒否するだけで、所有権が同じ接続かどうかを表現しない。

open の `0028` はミュート解除成功後に `storedCapturer` をクリアする問題だけを扱っている。別接続による capturer 取得を防ぐ所有権管理は同 issue のスコープ外である。

また、`PeerChannel.initializeCameraVideoCapture`(接続時カメラ起動)と `PeerChannel.terminateSenderStream`(切断時停止)は `VideoHardMuteActor` を経由せず `CameraVideoCapturer.current` の static state を直接参照するため、接続間の capturer 混線の迂回経路となり得る。本 issue ではこの迂回はスコープ外とし、`0103` の owner への集約で解決する。

## 再現手順

1. カメラ送信が可能な実 `MediaChannel` A と B を作成する。
2. A で `setVideoHardMute(true)` を呼び、capturer を停止する。
3. B で `setVideoHardMute(false)` を呼ぶ。
4. A が停止した capturer の `stream` が B の sender stream に変更されるか確認する。
5. A と B の mute / unmute 順序を交差させて反復する。

## 設計方針

- カメラ操作の所有者を示す lease を導入する。`MediaChannel` は単回使用で 1 つの `MediaChannel` が 1 回の `Sora.connect()` に対応するため、lease の接続識別は `MediaChannel` identity で表現する（`0095` / `0093` が定義する論理接続 ID と同義であり、用語を揃える）。`ObjectIdentifier` は dealloc 後のアドレス再利用 (ABA) で別インスタンスと同一値になり得るが、切断時に保存状態が破棄されるため実運用では発生しない。将来カメラ状態 owner（`0103`）を導入する際に、論理接続 ID（UUID 等）へ移行する。
- 保存する capturer、停止時の stream、操作 generation を lease に紐付ける。
- mute、unmute、disconnect では、操作開始時と各 `await` 復帰後に lease と generation を再確認する。camera flip の stream 設定順・generation 照合と hard mute の交差は `0099` が担当し、本 issue では扱わない。画面共有中は既存の `isScreenCaptureActive` チェックで unmute をブロックする挙動と整合させる。
- 別 lease が保存した capturer を restart しようとした場合、または別 lease が保存状態を持つ間に start 経路で共有カメラを起動しようとした場合は、明示的な `SoraError.mediaChannelError` で拒否する。共有カメラの取得・停止・再開は lease の所有に紐付け、別 lease が保存状態を持つ間は start・restart のどちらの経路でも共有カメラを別の sender stream へ付け替えられないことを保証する。ここでの「start / restart 経路」とは `VideoHardMuteActor.setMute` 内の start / restart を指し、`PeerChannel.initializeCameraVideoCapture`(接続時カメラ起動)と `PeerChannel.terminateSenderStream`(切断時停止)は本 issue の対象外とする。これらの経路は `CameraVideoCapturer` の static state を直接参照しており、`VideoHardMuteActor` を経由しないため、`0103`(カメラ状態を接続 lease 付き owner へ集約する)で owner の command として集約する際に解決する。
- 接続切断時に、その接続が所有する保存状態を破棄する。
- `MediaStream` を `SenderStreamBox: @unchecked Sendable` で広域に渡す構造は拡大しない。現状は該当する内部 handle が存在しないため、`SenderStreamBox` による受け渡しを維持する。`0105` が stream 用の内部 handle を導入した場合は、それを actor へ渡す方式へ変更できる。
- 利用者 callback と WebRTC オブジェクトの操作は、lease state を保護する actor 内へ無制限に持ち込まない。
- 本 issue は接続間の capturer 混線というバグに限定する。カメラ状態全体の executor 所有と `SenderStreamBox` の削除は別 issue とする。

## テスト方針

モックやスタブは使用しない。

- 2 つの実 `MediaChannel` と実カメラを使い、A mute、B mute / unmute、A unmute を交差させる。
- A が mute でカメラを停止・保存した状態で B が unmute を呼び、start / restart どちらの経路でも共有カメラが起動されず、明示的な `SoraError.mediaChannelError` で拒否されることを確認する。
- capturer と sender stream の identity を記録し、別接続の組み合わせにならないことを確認する。
- stop または restart の完了待ち中に別接続から操作し、`await` 復帰後の lease 再確認が機能することを検証する。
- 接続切断後、その接続が保存した capturer を別接続が取得できないことを確認する。
- 本 issue では lease と generation による所有権分離を先に確立する。解除成功時の lease 固有保存状態のクリアは `0028` で検証する。
- テストには、actor の直列化だけでは `await` をまたぐ所有権を保証できない理由を日本語コメントで明記する。

## 完了条件

- 保存する capturer が接続 lease と操作 generation に紐付いていること。
- 別の `MediaChannel` が保存した capturer を取得または restart できず、別 lease が保存状態を持つ間に `VideoHardMuteActor` 内の start 経路で共有カメラを起動しないこと。(`PeerChannel.initializeCameraVideoCapture` / `PeerChannel.terminateSenderStream` による迂回はスコープ外とし、`0103` で解決する)
- `await` 復帰後に lease と generation を再確認していること。
- disconnect 時に該当接続の保存状態が破棄されること。
- 複数接続の mute / unmute を交差させても capturer と sender stream が混線しないこと。
- `0028` が同一 lease の保存状態を安全にクリアできる ownership 情報を提供すること。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
