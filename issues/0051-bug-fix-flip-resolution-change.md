# flip を 2 回した時に解像度が変わってしまう問題を修正する

- Priority: Low
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/fix-flip-resolution-change
- Polished: 2026-10-30
- Updated: 2026-10-30

## 目的

`flip()` でカメラを前後に切り替えた際、バックカメラ → フロントカメラ → バックカメラという経路を経ると、接続時に `CameraSettings.resolution` で設定した解像度に戻らないバグを修正する。

## 優先度根拠

意図せぬ解像度の劣化は送信映像の品質に影響するため修正が必要。ただし、切り替え先カメラが送信元カメラの現在の解像度をサポートしない場合に発生し、フロントとバックの両方が同じ解像度に対応している場合は影響が出ない。Low とする。

## 現状

### バグの根本原因

`Sora/CameraVideoCapturer.swift` の `CameraVideoCapturer.flip(_:completionHandler:)` は `CameraVideoCaptureCoordinator` を経由して `flipUncoordinated(_:completionHandler:)` を呼ぶ。`flipUncoordinated` は切り替え先カメラのフォーマットを選択する際、`CameraSettings.resolution`（ユーザーが設定した目標解像度）ではなく「現在キャプチャしているフォーマットの実寸」を入力値として使っている:

```swift
let dimension = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
guard
  let format = CameraVideoCapturer.format(
    width: dimension.width,
    height: dimension.height,
    for: flip.device,
    frameRate: capturerFrameRate)
```

`CameraVideoCapturer.format(width:height:for:frameRate:)` は「指定解像度に最も近いフォーマット」を返す近似選択実装。

### バグの再現経路

1. バックカメラで 1080p（1920x1080）に設定して起動する
2. `flip()` でフロントカメラに切り替える。フロントカメラが 1080p をサポートしない場合、近似選択アルゴリズムにより近い解像度（例: 720p = 1280x720）が選択される
3. 再度 `flip()` でバックカメラに戻す。このとき入力値は「フロントカメラが実際に使っていた 720p（1280x720）」であるため、バックカメラでも 720p が選択され元の 1080p に戻らない

`PeerChannel.initializeCameraVideoCapture(stream:)` では `snapshot.cameraSettings.resolution.width` / `.height` を使って初期フォーマットを選択しているが、`flip()` は接続設定 (`PeerChannel.snapshot` の `ConnectionConfigurationSnapshot`) にアクセスする設計になっていないため、元の目標解像度が失われる。

## 設計方針

`0099` (2026-09-02 完了) は `flip()` の stream 設定順と rollback を修正する issue であり、本 issue を先行させないまま完了している。現行の `flip()` は start より前に切り替え先の stream を設定し、失敗時は compare-and-set で rollback するため、本 issue はこの構造を維持する。`0103` (2026-09-16 完了) はカメラ状態を owner へ集約する refactor であり、本 issue の未実装のまま完了している。現行では format は `CameraStateOwner` の resource テーブル、frameRate は reducer の state、stream は resource テーブルが保持しており、`targetResolution` もこの所有構造に合わせる。

`CameraVideoCapturer` に元の目標解像度を参照・設定する内部プロパティを追加し、`flip()` がそれを参照するように修正する。これにより `flip()` の public API シグネチャを変えずにバグを修正できる（シグネチャ変更は破壊的変更となるため避ける）。

`CameraVideoCapturer` は `Sendable` に準拠しており、型 doc と `0103` の完了条件に「instance の stored property は `id` / `deviceStorage` / `nativeStorage` の 3 つだけ」と記録されている。そのため可変の stored property は追加せず、目標解像度は `CameraStateOwner` が capturer ID ごとに保持し、`CameraVideoCapturer` には owner 経由で読み書きする `internal var targetResolution: CameraSettings.Resolution?` を computed property として追加する。getter は owner から値を読み、setter は owner へ書き込む。`nil` の場合は現在フォーマットの実寸を使う。値は `CameraStateOwner.release(id:)` の解放経路で破棄し、capturer の解放後も残らないようにする。

追加するプロパティと owner 側の API には、AGENTS.md の「コメントはしっかり入れること」の規約に従いコメントを付けること。

`PeerChannel` は `CameraVideoCapturer` と同一モジュール内のため `internal` で十分。

`PeerChannel.initializeCameraVideoCapture(stream:)` では、`cameraCaptureCoordinator.enqueue` を呼ぶ前に `let targetResolution = snapshot.cameraSettings.resolution` として値を取り出し、`enqueue` する closure 内で `capturer.startForSDK(format:frameRate:senderStream:)` を呼ぶ直前に `capturer.targetResolution = targetResolution` を設定する。このメソッドの start 呼び出しは 1 箇所であり、送信先 stream は `senderStream:` 引数で渡って `startForSDK` 内で start より前に設定されるため、旧来の `capturer.stream = stream` の直前に合わせる必要はない。

カメラを開始する経路は `PeerChannel.initializeCameraVideoCapture(stream:)` のほかに、`VideoHardMuteActor.startCameraVideoCapture(cameraSettings:senderStream:lease:cameraStartAuthorization:)`（ハードミュート解除時に保存済みの capturer が無い場合）と、公開 `CameraVideoCapturer.start(format:frameRate:completionHandler:)` がある。`VideoHardMuteActor.startCameraVideoCapture` では `capturer.startForSDK(format:frameRate:senderStream:)` を呼ぶ直前に `capturer.targetResolution = cameraSettings.resolution` を設定する。`CameraSettingsSnapshot` は `resolution` を保持しているため、設定値の受け渡し経路は既存のものをそのまま使える。公開 `start` は呼び出し側が `AVCaptureDevice.Format` を明示するため、`CameraVideoCapturer.current` が `nil` であることを確認した後、`startForSDK` を呼ぶ前に `capturer.targetResolution` を `nil` に戻す。これにより接続経路以外で起動した capturer は `nil` フォールバック（現在フォーマットの実寸）を使う。

`flipUncoordinated(_:completionHandler:)` 内の `dimension` の算出を以下のように修正する。この場所では `guard let format = capturer.format` で取得した変数 `format` と、`guard let capturerFrameRate = capturer.frameRate` で取得した変数 `capturerFrameRate` が利用できる:

```swift
// 修正後: targetResolution があればその目標解像度を使う。なければ実寸にフォールバック
let dimension: CMVideoDimensions
if let target = capturer.targetResolution {
    dimension = CMVideoDimensions(width: target.width, height: target.height)
} else {
    dimension = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
}
```

`flip` の start 成功時 (`finish` closure の成功分岐で `owner.setFormat(format, id: flip.id)` を呼ぶ箇所) に `flip.targetResolution = capturer.targetResolution` を追加して目標解像度を引き継ぐ。

`change(format:frameRate:completionHandler:)` は `AVCaptureDevice.Format?` / `Int?` を引数に取り、未指定時は現在の format / frameRate を引き継ぐ。`targetResolution` は変化させない方針とする。そのため `change()` 後に `flip()` を呼ぶと接続時の目標解像度が使われ、`change()` で指定した解像度とは異なる解像度が選ばれる場合がある。この動作は本 issue では許容する。

open の `0142` は送信するカメラ映像の出力サイズと contain / cover を扱い、接続側の設定を capturer に保持させる設計を予定している。本 issue の `targetResolution` の保持先と交差するため、`0142` の実装時には保持先を揃える。

## テスト方針

モック・スタブは使用しない。`flip()` の解像度選択は実カメラが必要なため、実機または実カメラが利用可能な環境で確認する。iOS Simulator では実カメラを利用できない。owner の `targetResolution` の保持は実カメラ不要で検証する。

- フロントカメラが 1080p（1920x1080）をサポートしない実機で、1080p 設定から `flip()` を 2 回（バック → フロント → バック）実行し、バックカメラが再び 1080p で動作することを確認する。フロントカメラが 1080p をサポートする実機では修正前でも同じ結果になるため、この条件を満たす実機を使う。
- `flip()` を 1 回実行した場合、切り替え先カメラが `targetResolution` に最も近い解像度を選択することを確認する。初期カメラが `targetResolution` の解像度で動作している場合は修正前と同じ結果になる。初期カメラが `targetResolution` をサポートしない場合は、修正前と選択結果が変わり得る。
- `initialCameraEnabled = false` で接続し、`setVideoHardMute(false)` でバックカメラを 1080p 設定で起動した後、`flip()` を 2 回実行し、バックカメラが再び 1080p で動作することを確認する。フロントカメラが 1080p をサポートしない実機を使う。
- `targetResolution` が `nil` の場合、従来通り現在のフォーマットの実寸を基準に選択されることを確認する。`nil` になる経路は、公開 `CameraVideoCapturer.start(format:frameRate:)` で起動した場合など接続経路以外に限られる。
- `change(format:frameRate:completionHandler:)` 実行後にも `targetResolution` が変化しないことを確認する。`change()` 後に `flip()` を呼ぶと接続時の目標解像度が使われるため、`change()` で指定した解像度とは異なる解像度が選ばれる場合がある（修正前の挙動とは異なる）。
- `CameraStateOwnerTests` に、owner の `targetResolution` の設定・取得（既定値 `nil`）と capturer 解放時の破棄を、実カメラ不要で検証するテストを追加する。`flip()` の解像度選択と公開 `start` による `nil` への戻しは実カメラが必要なため実機で確認する。

## 完了条件

- フロントカメラが 1080p（1920x1080）をサポートしない実機で、バックカメラを 1080p に設定して接続した後、`flip()` を 2 回（バック → フロント → バック）実行すると、バックカメラが再び 1080p で動作すること
- `flip()` を 1 回（バック → フロント）実行した場合、フロントカメラが `targetResolution` に最も近い解像度を選択すること。初期カメラが `targetResolution` の解像度で動作している場合は修正前と同じ結果になること
- `targetResolution` が `nil` の場合（公開 `CameraVideoCapturer.start(format:frameRate:)` で起動した場合など）は従来通り現在のフォーマットの実寸を基準に選択されること
- `PeerChannel.initializeCameraVideoCapture(stream:)` の `startForSDK(format:frameRate:senderStream:)` 呼び出し前に `capturer.targetResolution` を設定していること
- `initialCameraEnabled = false` で接続し、`setVideoHardMute(false)` でバックカメラを 1080p 設定で起動した場合でも、`flip()` を 2 回実行するとバックカメラが再び 1080p で動作すること（フロントカメラが 1080p をサポートしない実機を使う）。`VideoHardMuteActor.startCameraVideoCapture` の `startForSDK` 呼び出し前に `capturer.targetResolution` を設定していること
- 公開 `CameraVideoCapturer.start(format:frameRate:)` で起動した capturer では `targetResolution` が `nil` に戻り、`flip()` が現在のフォーマットの実寸を基準に選択すること
- `change()` を呼んでも `targetResolution` は変化しないこと（`change()` 後に `flip()` を呼ぶと接続時の目標解像度が使われるため、`change()` で指定した解像度とは異なる解像度が選ばれる場合がある）
- `CameraStateOwner.release(id:)` で capturer を解放した後、その capturer の `targetResolution` が破棄されていること
- 追加したテストと既存テストがすべて成功すること
- `CHANGES.md` の `## develop` セクションにある既存の `[FIX]` エントリの最後に以下を追記すること

```
- [FIX] flip を 2 回した時に元の解像度に戻らないバグを修正する
  - @voluntas
```
