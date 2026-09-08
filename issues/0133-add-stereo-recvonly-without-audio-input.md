# ネイティブ stereo の受信専用接続でマイク入力を不要にする

- Created: 2026-09-07
- Completed: {YYYY-MM-DD}
- Branch: feature/add-stereo-audio-output
- Polished: {YYYY-MM-DD}

## 目的

音声を送信しないネイティブ stereo の受信専用接続を、マイク権限やマイク入力なしで利用できるようにする。

## 修正前の動作

調査対象は PR #381 のコミット `16cba6346931d9d631e7061cb5632d193c1a2cb8` と libwebrtc `m150.7871.3.2` である。

- `MediaChannel` はネイティブ stereo を送受信方向によらず `.stereoRemoteIO` に分類する。
- `AudioSessionUsage.requiresPlayAndRecord` はこのプロファイルで true になる。
- `PeerChannel` は stereo の場合に VoiceProcessingIO 向けの入力初期化を省略するが、RemoteIO 自身は入力を有効にする。
- SDK 側で入力初期化の呼び出しを省略するだけでは、マイク依存を取り除けない。

## 設計方針

- webrtc-build issue 0014 による既存 `RTCAudioSession.initializeInput` の RemoteIO 対応を取り込む。新しい入力設定 API や入力不要の固定プロファイルは追加しない。
- `MediaChannel`、`AudioSessionUsage`、`NativePeerChannelFactory` の設定を揃え、受信専用で `playAndRecord` を必須としない。
- `initializeSenderStream` の既存の送信側の判断を使用する。マイクを送信する `sendonly` と `sendrecv` では、stereo 時の入力初期化スキップを除き、既存の `setInitialMicrophoneMute` と `initializeInput` を呼ぶ。受信専用では呼ばない。
- `AudioSessionUsage.stereoRemoteIO` の `requiresPlayAndRecord` を `configuration.isSender` に従わせ、AudioUnit の種類による競合判定と入力の要否を分ける。入力の要否のために ADM 再生成の制約を追加しない。
- 新しいネイティブビルドへの依存更新と入力初期化の呼び出し復元を同時に行う。ネイティブ側だけ先に更新すると stereo 送信が入力を初期化しなくなる。
- 音声無効、PCMU、カスタム音声デバイスなど、既存の設定検証との整合を保つ。
- webrtc-build issue 0016 と合わせて、ステレオ時の初期ミュートと `setAudioHardMute` の制約を解除する。SDK 独自のミュート状態キャッシュは持たず、ADM に要求を渡して実際の戻り値を返す。
- stereo 録音への対応を扱う既存 issue 0009 とは目的を分ける。

## 対応ブランチと依存関係

ユーザー指定の例外として、PR #381 の `feature/add-stereo-audio-output` に含める。
webrtc-build の `feature/m150.7871` をベースにした [issue 0014 の PR #176](https://github.com/shiguredo-webrtc-build/webrtc-build/pull/176) を先に取り込む。
ネイティブ側は既存 API を共通化する方針で実装し、`0014 → 0015 → 0016` のスタックにしている。
ハードミュートには [issue 0016 の PR #174](https://github.com/shiguredo-webrtc-build/webrtc-build/pull/174) の入力 I/O 制御、初期ミュート解除、worker スレッドでの録音操作が必要である。
issue 0132 の競合判定を維持したまま入力の要否を反映し、実機確認は issue 0134 と合わせて行う。
依存ビルドの取り込みは issue 0130 と調整する。

## テスト方針

既存の送受信の判断、カテゴリ要求、入力初期化の呼び出しを自動テストで確認する。
実機ではマイク権限が未決定・拒否の両方で受信専用接続を行い、権限ダイアログが出ず、入力を使用せずに左右の音声を再生できることを確認する。
送受信接続と再接続も確認し、モックやスタブは使用しない。

## 完了条件

- ネイティブ stereo の `recvonly` がマイク権限を要求せずに動作する。
- マイク権限が拒否された端末でも、受信専用の再生を開始できる。
- `sendonly` と `sendrecv` は必要な入力を使用して動作する。
- 切断、再接続、経路変更によって受信専用の入力が有効にならない。
- 設定の説明、エラー条件、AudioSession の競合判定が、既存の送受信の判断と入力初期化に一致する。

## 解決方法

2026-09-07、PR #381 の作業ブランチで次を修正した。

- `PeerChannel.initializeSenderStream` から stereo による入力初期化スキップを除き、既存の送信側の判断で `initializeAudioInput` を呼ぶ。受信専用では呼ばず、カスタム音声デバイスの入力初期化は引き続きそのデバイスに任せる。
- `AudioSessionUsage.stereoRemoteIO` に送信側かどうかを渡し、受信専用では `playAndRecord` の予約・適用を行わない。AudioUnit profile による既存の競合判定を維持する。
- ステレオ送信側の `initialMicrophoneEnabled=false` と `setAudioHardMute` を受け付ける。ハードミュートの接続状態・音声有効・送信側の検証は共通経路を使う。
- `AudioDeviceModuleWrapper` の `isHardMuted` を除き、初期状態や失敗後の同じ要求を成功扱いで省略しない。
- factory の生成失敗をエラーとして扱う。

### 検証結果

- 変更した Swift ファイルのフォーマット検査が成功した。
- 変更した Swift ファイルの strict SwiftLint が成功した。SDK 全体では 190 テスト中、成功 169、Sora 接続情報の未設定などによるスキップ 21、失敗 0 だった。
- 実際の ADM と MediaChannel を使う `AudioDeviceModuleWrapperTests` と `StereoAudioOutputTests` の 34 件が成功した。受信専用では category を変更せず、sendonly / sendrecv では `playAndRecord` を要求し、最後の接続解放後に元へ戻ることを確認した。
- 未初期化の実際の ADM に対する最初のミュート解除と再試行が失敗を返し、SDK が失敗を成功扱いにしないことを確認した。
- SDK のビルド・テストは `Package.swift` の m150.7871.3.2 を使用している。新しいネイティブとの通信・入力 I/O の統合検証ではない。

### 残る対応

対応するネイティブビルドは未公開であり、`Package.swift` のバージョンと checksum の更新は未実施である。
m150.7871.3.2 の `initializeInput` は VPIO 専用であり、呼び出しを戻すだけでは RemoteIO の手動入力初期化は行われない。
この SDK 変更と、0014〜0016 を含むネイティブへの依存更新を合わせて提供する必要がある。
依存更新後に、実機の recvonly / sendonly / sendrecv、初期ミュートから最初の解除、マイク音声・左右の再生音・インジケーターを確認する。
依存更新と実機検証が残るため、本 issue は open のままとする。
