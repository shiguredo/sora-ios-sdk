# VideoHardMuteActor の解除成功時の保存状態クリアを検証する

- Priority: Medium
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/fix-videohardmuteactor-stored-capturer-clear
- Polished: 2026-08-27
- Updated: 2026-10-30

## 目的

`VideoHardMuteActor` がミュート解除用に保持する保存状態を、解除成功時にクリアする。保存状態が残り続けると状態遷移の意図が不明瞭になり、不要な参照保持と将来の改修時の不整合リスクを招くため、解除成功時に破棄する。

クリアのコード変更は実装済みで `2026.3.0` 以降に出荷されている (`## 現状` の「実装の経緯」)。本 issue の残作業は、実機での動作確認と、解除失敗時に保存状態を保持する現行挙動の判断根拠を `## 解決方法` に記録することである。確認で不具合が見つからない限り、本 issue ではコード変更を行わない。

## 優先度根拠

- 状態管理の不具合であり、古い参照を前提とした不整合や保守性低下を将来招き得る。バグとして扱うため Medium とする。
- 即時のクラッシュやデータ破壊ではないため High ではない。
- 本 issue が求めるクリア挙動は実装済みであり、残っているのは検証と記録である。

## 現状

`Sora/VideoMute.swift` の `VideoHardMuteActor` は、ミュート有効化時に停止した capturer を解除時の再開用に lease ごとの辞書 `storedCapturers: [VideoHardMuteLease: CameraCapturerID]` で保持し、instance の生存を `CameraStateOwner.pin(id:instance:)` で保証する。

ミュート解除時 (`mute = false`) の処理は次の 3 経路に分かれる。経路 A と経路 B は成功時に `discardStoredCapturer(lease:)` を呼び、保存状態と pin を破棄する。経路 C へ進むのは `storedCapturers[lease]` が nil の場合だけであり、破棄すべき保存状態は残っていない。

- 経路 A: `currentCameraVideoCapturerAndCompleteStart(senderStream:lease:cameraStartAuthorization:)` が返した capturer の stream が自分の sender stream と同一なら、既に再開済みとして成功する。
- 経路 B: `storedCapturers[lease]` の ID を `CameraStateOwner.capturer(id:)` で解決し、`restartCameraVideoCapture` で再開して成功する。
- 経路 C: 保存状態がないため `startCameraVideoCapture` で新規に開始する。

`MediaChannel.videoHardMuteActor` は全接続共有の `static let` であり、`CameraVideoCapturer.current` も process 全体で共有される。そのため経路 A は sender stream の同一性で自分の接続の capturer かを判定する。別接続の active capturer を観測した場合は `SoraError.mediaChannelError(reason: "camera is owned by another connection")` を投げ、元接続の保存状態を破棄しない。

### 実装の経緯

- 解除成功時のクリアは `003bb738` (2026-09-08) で成立し、`2026.3.0` (2026-09-10) に含まれる。当該コミットは `0010` (ステレオ音声出力) の PR (#381) であり、本 issue として実装されたものではない。
- `e4291a87` (`0103`, 2026-09-17) が保存する値を `CameraCapturerID` に変え、破棄を `discardStoredCapturer(lease:)` (pin の解放を含む) へ整理した。`2026.4.0` (2026-10-20) に含まれる。
- 経路 A と経路 B のクリアを検証するテストはない。`storedCapturers` は private で、`SoraTests` から保存状態の有無を直接観測できない。

## 前提となる issue

- `0098` (closed, 2026-09-02): `VideoHardMuteLease` による所有権分離と sender stream の照合を導入した。当時導入した lease ごとの破棄予約世代 (`leaseGenerations`) は、現在は `VideoHardMuteLease.revoke()` / `isValid` に置き換わっている。
- `0103` (closed, 2026-09-16、実装コミット `e4291a87` は 2026-09-17): 保存する capturer を `CameraCapturerID` に変更し、破棄を `discardStoredCapturer` (pin の解放を含む) へ整理した。クリア条件は変更していない。

本 issue が定めていた「`0098` → 本 issue → `0103`」の実施順序は意味を失っている。解除成功時のクリアは `003bb738` (2026-09-08) で `0103` より先に成立し、`0103` はその条件を変えずに保存形式を整理した。

## 設計方針

connection lease ごとの保存状態について、同一 lease の unmute が成功した場合だけ保存状態をクリアする (実装済み)。

- 経路 A は sender stream の同一性で自分の接続の capturer かを判定し、一致した場合だけ成功として保存状態を破棄する。capturer は lease を保持しない。`generation` 引数は `VideoHardMuteActor` の `mute = false` 経路では使わず、解除後の `videoEnabled` の確定は `MediaChannel.setVideoHardMute(false)` が同じ世代で行う。`cameraStartAuthorization` が渡された場合は同じ直列化区間で予約を確定し、lease が無効なら開始したカメラを停止して取消エラーを返す。
- 経路 B は同じ lease が所有する capturer の restart 成功後に破棄する。
- 経路 C は `storedCapturers[lease]` が nil の場合だけ通るため、新規 start 成功時に同じ lease の保存状態は残っていない (明示的な破棄呼び出しはない)。
- 別接続の active capturer を観測した場合は元接続の保存状態を破棄せず、`0098` が導入した `SoraError.mediaChannelError` による拒否に従う。
- disconnect 時は `VideoHardMuteLease.revoke()` と `release(lease:)` で保存状態を破棄する。`MediaChannel` は 1 回の `Sora.connect()` ごとに生成されて再利用されず、lease も `MediaChannel` ごとに 1 個生成される。redirect では `transportEpoch` が進むが `MediaChannel` と lease は変わらないため、保存状態の所有は接続試行単位で固定である。

**解除失敗時の挙動**:

`restartCameraVideoCapture` が throw した場合、および隔離後の再開失敗 (`"camera capture is quarantined after a cleanup failure"`) の場合は、保存状態と pin を保持し、同じ lease の再試行に利用する。disconnect または別 lease からの操作では利用できない。保存する instance を解決できない場合だけ保存状態を破棄し、`SoraError.mediaChannelError(reason: "stored capturer is no longer available")` を返す。

ここでの「解除成功」は `VideoHardMuteActor.setMute(mute: false)` が throw せずに完了した時点を指す。`MediaChannel.setVideoHardMute(false)` が引き続き `videoSourceCoordinator.isValid(_:)` を確認して取消エラーを返す場合でも、actor 側の保存状態は破棄済みである。

解除失敗時に保存状態を破棄する条件の追加・変更は本 issue では行わない (必要なら別 issue)。`## 解決方法` には、現行どおり保持する判断根拠を記録する。

**後方互換性**: クリアは内部状態の変更のみであり、公開 API の `setVideoHardMute` の外形的な挙動は変えない。別 lease 起因のエラー化は `0098` が導入済みで `2026.3.0` に含まれる。本 issue の残作業は検証と記録であり、コード変更を予定していない。

## テスト方針

モック・スタブは使用しない。接続済みの sender role、映像有効、`cameraSettings.isEnabled == true`、sender stream と video track が存在する条件で、実カメラを使って確認する。`storedCapturers` は private で、保存状態の有無をテストや実行時に直接観測できない。また、実カメラが必要な分岐は iOS Simulator では到達できず、SwiftPM のテストターゲットは tool-hosted で実機実行できない (`VideoHardMuteRollbackE2ETests` と同じ制約)。そのため、保存状態が破棄されたことはコードで確認し、それ以外の項目は実機での手動確認で判定する。

- `mute = true` → `mute = false` (restart 経路) の順で呼び出し後、映像が再開されること。
- `initialCameraEnabled = false` で接続し、最初に `mute = false` を呼ぶ start 経路で映像が起動すること。
- 同一 lease の capturer で経路 A を通る `mute = false` の後も、映像が再開されたままであること。保存状態が破棄されたことはコードで確認する。
- 別 `MediaChannel` が camera を起動した状態で `mute = false` を呼ぶと、`SoraError.mediaChannelError(reason: "camera is owned by another connection")` で失敗すること。元接続の保存状態が破棄されないことはコードで確認する。
- 連続した `mute true/false` の繰り返し (3 回以上) で毎回期待どおり再開できること。
- 解除後に再度 `mute = true` を呼び出しても正常にミュートできること (`storedCapturers` の二重設定が起きないこと)。
- restart 失敗後の再試行は同じ connection lease だけが実行できること (restart の失敗を実機で決定的に再現する手順がないため、コードで確認する)。

## 完了条件

実装済み (現行コードで確認済み):

- `mute = true` で停止後に `storedCapturers[lease]` が設定され、`CameraStateOwner` に pin されること。
- `mute = false` で同一 connection lease の解除成功後 (経路 A・B) に、その lease の保存状態と pin が破棄されること。経路 C は保存状態がない場合だけ通るため対象外。
- 別接続の active capturer を観測しても、元接続の保存状態を破棄しないこと。
- 解除失敗時の保存状態が同じ connection lease 以外から利用されないこと。
- disconnect 時に古い保存状態が残らないこと。

実機で検証済み (2026-10-30、iPhone 14 / iOS 27.2):

- `mute = true` → `mute = false` (restart 経路) の後に映像が再開すること。
- `initialCameraEnabled = false` で接続し、最初の `mute = false` (start 経路) で映像が起動すること。
- 同一 lease の capturer で経路 A を通る `mute = false` の後も、映像が再開されたままであること。
- 別 `MediaChannel` が camera を起動した状態で `mute = false` を呼ぶと、`SoraError.mediaChannelError(reason: "camera is owned by another connection")` で失敗し、もう一方の接続の映像が止まらないこと。
- 連続した `mute true/false` (3 回以上) で毎回映像が再開すること。
- 解除後に再度 `mute = true` を呼んでも正常にミュートできること。

テストで検証済み (2026-10-30):

- `xcodebuild test` (`Sora-Package` scheme、iPhone 17 Pro の iOS Simulator、Xcode 27.0) で 553 件実行、失敗 0、skip 39。skip は `SORA_SIGNALING_URL` などの環境変数が未設定の E2E と、実カメラや実行環境に依存する検証によるものです。

未完了:

- クローズ時に `## 解決方法` へ次を記録すること。
  - 実装の経緯と、解除失敗時に保存状態と pin を保持する現行挙動の判断根拠
  - テスト方針のうち実機で観測できない項目 (経路 A の保存状態破棄、別接続時に元接続の保存状態が破棄されないこと、restart 失敗後の lease 制限) のコード確認結果
  - 実機確認とテスト実行の結果 (端末・OS・日付・件数)

取り下げ:

- `CHANGES.md` への追記。クリアは内部状態の変更のみで `2026.3.0` で出荷済みのため、`## develop` (次期リリース) にも `## 2026.3.0` (過去のリリース) にも追記しない。

## 解決方法
