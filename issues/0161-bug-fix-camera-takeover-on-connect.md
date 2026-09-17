# 接続時のカメラ起動が別接続のカメラを無通知で停止して奪う

- Created: 2026-09-17
- Completed:
- Priority: Low
- Branch: feature/fix-camera-takeover-on-connect
- Polished:

## 目的

カメラを要求して接続した接続が、既に別接続が使用中のカメラを停止して奪う挙動と、奪われた側に何も通知されない挙動を解消する。

`setVideoHardMute` は「別接続が使用中のカメラ」を `camera is owned by another connection` で拒否するのに対し、`Sora.connect` の接続時カメラ起動は同じ要求を強奪として通す。同じ意図の操作が API によって逆の結果になる状態を揃える。

## 現状

`Sora/PeerChannel.swift` の `initializeCameraVideoCapture` は、`CameraVideoCapturer.current` が存在し、その `stream` が自分の送信ストリームと異なる場合、`stopForSDK()` で動作中のカメラを停止してから自分のカメラを起動する。停止後は `CameraCaptureOwnership.clear(ifOwnedBy:)` と `VideoSourceCoordinator.releaseCameraReservations(for:excluding:)` で前の接続の所有情報を破棄するため、所有権は新しい接続へ移る。

`Sora/VideoMute.swift` の `VideoHardMuteActor.setMute` は同じ状況を `camera is owned by another connection` で拒否する。つまり「別接続がカメラを使用中に、もう 1 つの接続がカメラを欲しがる」という同じ要求に対して、接続経路は強奪、ハードミュート経路は拒否という逆の結果になる。

奪われた側には接続レベルの通知が無い。`MediaStream.videoEnabled` は `true` のまま、`MediaStreamHandlers` のコールバックも発火しない。観測できるのは `CameraVideoCapturerHandlers` の `onStop` だけで、これはプロセス全体で共有されるため「どの接続のカメラが止まったか」を区別できない。奪われた接続の `setVideoHardMute(true)` は `camera is owned by another connection` で失敗するため、ソフトミュートと切断以外に映像を止める手段が無くなる。

`initializeCameraVideoCapture` には型 doc コメントが無く、この譲渡仕様はコードを読まないと分からない。`0098` はこの経路を capturer 混線の迂回経路として `0103` へ先送りし、`0103` は owner 経由の読み取りに変更したが可否判定は変えていない。

## 再現手順

実機で同一プロセスに sender role の接続を 2 本作り、1 本目でカメラを起動した状態で 2 本目を `initialCameraEnabled = true` で接続する。

1. A を `initialCameraEnabled = true` で接続し、カメラが動作していることを確認する
2. B を `initialCameraEnabled = true` で接続する
3. A のカメラが停止し (`succeeded to stop`)、続けて B のカメラが起動する (`succeeded to start`)
4. A の `MediaStream.videoEnabled` は `true` のまま変化しない
5. B がカメラを解放しても A は自動的にカメラを取り戻さない

## 設計方針

次のいずれかを実装時に決める。

- 接続時カメラ起動も所有権 guard で拒否し、要求した側にも拒否を通知する
- 譲渡を仕様として維持する場合、譲渡時に前の接続へ通知し `videoEnabled` を `false` にする
- 譲渡を明示的なオプションにする

いずれの場合も `initializeCameraVideoCapture` の型 doc と `skills/sora-ios-sdk/SKILL.md` に挙動を明記する。

## 優先度根拠

複数接続でカメラを同時に使う具体的なユースケースが現時点で確認できていないため Low とする。実機での再現は可能で、発生すると映像が無通知で止まるため、ユースケースが見つかった時点で優先度を見直す。

## 完了条件

- 接続時カメラ起動と `setVideoHardMute` の可否判定が一貫していること
- 譲渡が起きた場合に前の接続が検知できること (通知または `videoEnabled` の更新)
- 上記が型 doc と `skills/sora-ios-sdk/SKILL.md` に記載されていること
- 実機で再現手順を通し、期待どおりの結果になること
- 追加したテストと既存テストがすべて成功すること

## 解決方法
