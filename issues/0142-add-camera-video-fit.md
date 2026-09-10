# 送信するカメラ映像の出力サイズ指定と contain / cover に対応する

- Created: 2026-09-10
- Completed: {YYYY-MM-DD}
- Branch: feature/add-camera-video-fit
- Polished: {YYYY-MM-DD}

## 目的

送信するカメラ映像の出力サイズを指定し、カメラ映像をそのサイズへどのように収めるかを CSS の object-fit 相当の contain / cover で選べるようにする。利用者から、送信するカメラ映像のサイズと縦横比の扱いを指定したいという要望が挙がっている。カメラの取得フォーマットの縦横比と、アプリが送信したい映像の縦横比が一致しない場合に、切り取り (cover) と余白 (contain) の扱いを SDK 側で統一できるようにする。

## 現状

- `Configuration.cameraSettings` の `CameraSettings` で指定できるのは取得解像度 (`resolution`)、フレームレート、カメラ位置、カメラの有効無効のみで、送信する映像の出力サイズや縦横比を指定する API は無い。
- `CameraVideoCapturer` は `RTCCameraVideoCapturer.startCapture(with:format:fps:)` に `AVCaptureDevice.Format` を渡すため、カメラが出力するフォーマットのサイズがそのまま送信フレームのサイズになる。
- カメラのフレームは `CameraVideoCapturerDelegate.capturer(_:didCapture:)` から `MediaStream.send(videoFrame:)` へ渡される。`MediaStream.send(videoFrame:)` は `videoFilter` を適用した後に `RTCVideoSource.capturer(_:didCapture:)` へフレームを渡し、SDK 標準でサイズ指定や切り取りを行う仕組みは無い。
- `CameraVideoCapturer.handlers.onCapture` と `VideoFilter` を使えば利用者がフレームを差し替えられるが、contain / cover の計算とバッファ生成は利用者側の実装になる。
- `RTCVideoSource.adaptOutputFormatToWidth:height:fps:` は指定サイズへの縮小と縦横比に合わせた切り取り (cover 相当) を行うが、SDK からは呼ばれていない。contain の余白生成と拡大には対応していない。
- WebRTC の `RTCVideoFrameBuffer` プロトコルには任意実装の `cropAndScaleWith:offsetY:cropWidth:cropHeight:scaleWidth:scaleHeight:` があり、`RTCCVPixelBuffer` が実装している。ピクセルデータを再確保せずに切り取りと拡大縮小ができる。

## 設計方針

- `CameraSettings` に映像の出力サイズ (`width` / `height`) とフィットモード (`contain` / `cover`) を追加する。出力サイズ未指定時はカメラフォーマットのサイズをそのまま送信し、現状の挙動を変えない。
- 変換は `CameraVideoCapturerDelegate.capturer(_:didCapture:)` で行い、変換後のフレームを `MediaStream.send(videoFrame:)` へ渡す。`onCapture` ハンドラには変換後のフレームを渡し、ハンドラがフレームを返した場合は従来どおりそれを送信する。デフォルト無効のため既存のハンドラ利用者の挙動は変わらない。
- cover は、フレームの回転を考慮した表示サイズと出力サイズから中央基準の切り取り矩形を計算し、`cropAndScaleWith:offsetY:cropWidth:cropHeight:scaleWidth:scaleHeight:` で出力サイズへ拡大縮小する。
- contain は、フィットする矩形を計算した上で、出力サイズの `CVPixelBuffer` を新規作成して黒で塗り、`cropAndScaleTo:withTempBuffer:` で中央に描画する。出力サイズが同じ間は `CVPixelBuffer` を使い回し、毎フレームの再確保を避ける。
- カメラフレームは `rotation` を持つため、切り取り矩形の計算は `RTCVideoFrame.width` / `height` (回転適用前) と `rotation` から表示サイズを求めて行う。変換後の `RTCVideoFrame` には元の `rotation` と `timeStampNs` を引き継ぐ。
- 変換の対象はカメラ由来の `RTCCVPixelBuffer` に限定する。画面共有などカメラ以外のフレームは対象外とする。
- カメラの `restart` / `change` / `flip` をまたいでも指定を維持する。`VideoHardMuteActor` がカメラを再起動する経路があるため、`CameraSettingsSnapshot` にも新しい設定を引き継ぐ。
- 接続中に出力サイズやフィットモードを変更する API は本 issue では追加しない。

## テスト方針

- contain / cover の切り取り矩形と出力サイズを計算するロジックを internal に切り出し、`SoraTests` から既知サイズのフレームを与えて検証する。モックやスタブは使用しない。
- 縦横比が一致する場合 (切り取り・余白が発生しない場合) と一致しない場合の両方で、切り取り矩形と出力サイズが期待どおりになることを検証する。
- `rotation` が 0 / 90 / 180 / 270 のフレームで切り取り矩形が正しく計算されることを検証する。
- 実機のカメラで縦持ち・横持ちの両方を確認し、送信側と受信側で指定サイズと余白・切り取りが意図どおりになることを確認する。
- Simulator ではカメラが利用できないため、Simulator で実行できない項目を未検証として区別する。

## 完了条件

- `CameraSettings` でカメラ映像の出力サイズと contain / cover を指定できること。
- cover でカメラ映像が指定サイズいっぱいに拡大縮小され、はみ出した部分が切り取られて送信されること。
- contain でカメラ映像の全体が指定サイズ内に収まり、残りの領域が黒くなって送信されること。
- 出力サイズを指定しない場合の送信フレームのサイズと既存 API の挙動が変わらないこと。
- 公開 API の doc コメントを追加すること。
- `CHANGES.md` に追加を記載すること。

## 変更対象ファイル

- `Sora/CameraVideoCapturer.swift`
- `Sora/Configuration.swift`
- `Sora/VideoMute.swift`
- `SoraTests/` (追加するテスト)

## 解決方法
