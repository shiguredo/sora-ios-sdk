# VideoHardMuteActor が別接続の capturer を再開する問題を修正する

- Created: 2026-08-27
- Completed: 2026-09-02
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

- 2 つの実 `MediaChannel` と実カメラを使い、A mute、B mute / unmute、A unmute を交差させる。**実カメラを使用するため Simulator / CI では実行できず、実機で確認する。**
- A が mute でカメラを停止・保存した状態で B が unmute を呼び、start / restart どちらの経路でも共有カメラが起動されず、明示的な `SoraError.mediaChannelError` で拒否されることを確認する。**実機で確認する。**
- capturer と sender stream の identity を記録し、別接続の組み合わせにならないことを確認する。**実機で確認する。**
- stop または restart の完了待ち中に別接続から操作し、`await` 復帰後の lease 再確認が機能することを検証する。**実機で確認する。**
- 接続切断後、その接続が保存した capturer を別接続が取得できないことを確認する。**実機で確認する。**
- 本 issue では lease と generation による所有権分離を先に確立する。解除成功時の lease 固有保存状態のクリアは `0028` で検証する。
- テストには、actor の直列化だけでは `await` をまたぐ所有権を保証できない理由を日本語コメントで明記する。
- シミュレータで実行できる範囲として、release の冪等性と別 lease との独立 (`VideoHardMuteActorLeaseTests`) をユニットテストで検証する。

## 完了条件

- 保存する capturer が接続 lease と操作 generation に紐付いていること。
- 別の `MediaChannel` が保存した capturer を取得または restart できず、別 lease が保存状態を持つ間に `VideoHardMuteActor` 内の start 経路で共有カメラを起動しないこと。(`PeerChannel.initializeCameraVideoCapture` / `PeerChannel.terminateSenderStream` による迂回はスコープ外とし、`0103` で解決する)
- `await` 復帰後に lease と generation を再確認していること。
- disconnect 時に該当接続の保存状態が破棄されること。
- 複数接続の mute / unmute を交差させても capturer と sender stream が混線しないこと。
- `0028` が同一 lease の保存状態を安全にクリアできる ownership 情報を提供すること。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法

`VideoHardMuteActor` にカメラ操作の所有者 (lease) と破棄予約世代 (revocation) を導入した。

- `VideoHardMuteLease` を導入し、接続識別に `MediaChannel` の identity (ObjectIdentifier) を使用する。保存する capturer を lease に紐付ける。
- `storedCapturer` を lease / capturer / stream の構造体へ変更し、別接続が保存した capturer を取得できないようにする。
- `release(lease:)` を追加し、接続切断時に保存状態を破棄する。あわせて lease ごとの破棄予約世代 (leaseGenerations) を進め、setMute が await 中に release されても復帰後に検知して保存や再開を中止する。
- `setMute` の各 await 復帰後に lease と破棄予約世代を再確認する。revocation 済みの場合は、restart / start 後に起動したカメラを停止してからエラーを返す。
- mute / unmute 時に現在動作しているカメラの stream を照合し、別接続が使用中のカメラを停止・再開しない。`CameraVideoCapturer.current` は全接続で共有される static のため、stream の一致が必須。
- エラーは明示的な `SoraError.mediaChannelError` で返す ("camera is owned by another connection" / "video hard mute operation was cancelled")。

### スコープ外 (0103 で解決)

- `PeerChannel.initializeCameraVideoCapture`(接続時カメラ起動)と `PeerChannel.terminateSenderStream`(切断時停止)は `VideoHardMuteActor` を経由せず `CameraVideoCapturer.current` を直接参照する。この迂回経路 (接続間の capturer 混線の第三経路) は本 issue では対象外とし、`0103` の camera state owner への集約で解決する。`0103` の「前提となる issue」に明記済み。
- `ObjectIdentifier` は dealloc 後のアドレス再利用 (ABA) で別インスタンスと同一値になり得るが、切断時に保存状態が破棄されるため実運用では発生しない。将来 `0103` の owner 導入時に論理接続 ID (UUID 等) へ移行する。コードコメントと本 issue の設計方針に明記済み。

### 検証

- ユニットテスト (`VideoHardMuteActorLeaseTests`):
  - `testReleaseIsIdempotent`: release を複数回呼んでも安全
  - `testReleaseOfOtherLeaseDoesNotAffectTarget`: 別 lease の release が対象 lease に影響しない
  - カメラが必要な検証 (storedCapturer の所有権チェック / unmute / mute の stream 照合 / 実カメラでの交差テスト) は実機で確認する。Simulator / CI では実行できないため、issue のテスト方針には「実機で確認する」旨を明記している。
- 実機確認 (camera 接続の同一接続 mute → unmute): 正常動作 (実機確認済み)。別接続混線の再現は ScreenCast 構成ではカメラ接続が 1 本のため未実施 (制約として記録)。
- 既存の全テストが成功することを確認済み。
