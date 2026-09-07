# ネイティブ stereo の受信専用接続でマイク入力を不要にする

- Created: 2026-09-07
- Completed: {YYYY-MM-DD}
- Branch: feature/add-stereo-audio-output
- Polished: {YYYY-MM-DD}

## 目的

音声を送信しないネイティブ stereo の受信専用接続を、マイク権限やマイク入力なしで利用できるようにする。

## 現状

調査対象は PR #381 のコミット `16cba6346931d9d631e7061cb5632d193c1a2cb8` と libwebrtc `m150.7871.3.2` である。

- `MediaChannel` はネイティブ stereo を送受信方向によらず `.stereoRemoteIO` に分類する。
- `AudioSessionUsage.requiresPlayAndRecord` はこのプロファイルで true になる。
- `PeerChannel` は stereo の場合に VoiceProcessingIO 向けの入力初期化を省略するが、RemoteIO 自身は入力を有効にする。
- SDK 側で入力初期化の呼び出しを省略するだけでは、マイク依存を取り除けない。

## 設計方針

- webrtc-build issue 0014 の受信専用 RemoteIO を取り込み、音声を送信しない接続では初期化前に入力不要のプロファイルを選択する。
- `MediaChannel`、`AudioSessionUsage`、`NativePeerChannelFactory` の設定を揃え、受信専用で `playAndRecord` を必須としない。
- 音声を送信する `sendonly` と `sendrecv` は、従来どおり入力を必要とするプロファイルを使う。
- 入力を使用する接続へ変更する場合は、ネイティブ側の契約に沿って ADM を再生成する。実行中の AudioUnit を暗黙に切り替えない。
- 音声無効、PCMU、カスタム音声デバイスなど、既存の設定検証との整合を保つ。
- stereo 録音への対応を扱う既存 issue 0009 とは目的を分ける。

## 対応ブランチと依存関係

ユーザー指定の例外として、PR #381 の `feature/add-stereo-audio-output` に含める。
webrtc-build の `feature/m150.7871` で issue 0014 を先に対応する。
issue 0132 の競合判定へ受信専用プロファイルを反映し、実機確認は issue 0134 と合わせて行う。
依存ビルドの取り込みは issue 0130 と調整する。

## テスト方針

プロファイル選択と設定検証を自動テストで確認する。
実機ではマイク権限が未決定・拒否の両方で受信専用接続を行い、権限ダイアログが出ず、入力を使用せずに左右の音声を再生できることを確認する。
送受信接続と再接続も確認し、モックやスタブは使用しない。

## 完了条件

- ネイティブ stereo の `recvonly` がマイク権限を要求せずに動作する。
- マイク権限が拒否された端末でも、受信専用の再生を開始できる。
- `sendonly` と `sendrecv` は必要な入力を使用して動作する。
- 切断、再接続、経路変更によって受信専用の入力が有効にならない。
- 設定の説明、エラー条件、AudioSession の競合判定が新しいプロファイルと一致する。

## 解決方法
