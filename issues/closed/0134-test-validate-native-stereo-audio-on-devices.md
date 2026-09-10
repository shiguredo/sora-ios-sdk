# ネイティブ stereo 出力の実機検証を整備する

- Created: 2026-09-07
- Completed: 2026-09-09
- Branch: feature/add-stereo-audio-output
- Polished: {YYYY-MM-DD}

## 目的

ネイティブ RemoteIO の左右の出力とライフサイクルを実機で確認し、stereo 設定の受付と物理的な stereo 再生を区別して説明できるようにする。

## 現状

調査対象は PR #381 のコミット `16cba6346931d9d631e7061cb5632d193c1a2cb8` と libwebrtc `m150.7871.3.2` である。

- `StereoAudioOutputTests` はネイティブ設定や MediaEngine の保持を検証するが、物理的な再生までは確認しない。
- 現在の音声 E2E テストは `DummyAudioDevice` の PCM を検証する。これはソフトウェアの音声経路を確認するものであり、RemoteIO や端末の出力経路の検証にはならない。
- stereo 設定が有効でも、出力経路や AudioSession の mode によって実際の再生が mono になる場合がある。
- 過去のユーザー指定により、マイク入力に依存する E2E テストは通常の CI から除外している。

## 設計方針

- 通常の CI では既存のソフトウェア経路のテストを維持する。実機を必要とする検証は手動手順または明示的に実行する検証環境として用意する。
- 左右を識別できる異なる信号を入力し、実際の出力で左右の分離を確認する。設定値、チャンネル数の報告値、RTP 統計だけを合格条件にしない。
- 検証時の依存ビルド、OS、端末種別、出力経路、category、mode、観測方法を記録する。端末識別子や接続用の秘密情報は記録しない。
- `recvonly` と `sendrecv`、切断後の再接続、割り込みからの復帰、利用可能な出力経路の変更を対象にする。
- stereo を確認できる経路と、HFP など mono になる条件を区別する。A2DP も入力の有無で実際に選ばれる経路を確認し、すべての組み合わせで stereo を期待しない。
- マイク権限が未決定・拒否の場合の受信専用動作と、送信時に入力が必要な動作を分けて確認する。
- 説明文では設定値と実際の出力を区別し、検証していない端末や経路への保証を追加しない。

## 対応ブランチと依存関係

ユーザー指定の例外として、PR #381 の `feature/add-stereo-audio-output` に含める。
手順は先に整備し、issue 0130 から 0133 と対応する webrtc-build の修正を取り込んだ最終ビルドで結果を確認する。
一般的な出力先の調査を扱う既存 issue 0050、ブラウザと SDK の E2E を扱う既存 issue 0088 とは目的を分ける。

## テスト方針

ネイティブ出力の検証に `DummyAudioDevice` を代用せず、実際の端末と出力機器を使う。
モックやスタブは使用しない。
必要な端末や出力機器を用意できない項目は未検証として残し、未実行の結果を合格にしない。

## 完了条件

- 他の作業者が再現できる実機検証の手順と期待結果が整備されている。
- 最終ビルドについて、stereo 対応の出力経路で実際の左右の分離を確認している。
- 受信専用、送受信、再接続、割り込み、権限、経路変更の結果を記録している。
- 対象とした経路ごとに合否と制約を示し、必要な未検証項目がある間は完了扱いにしない。
- 公開設定の説明が実測結果と整合し、通常の CI にマイク入力を必須とするテストを追加していない。

## 解決方法

2026-09-09、m150.7871.3.5（webrtc-build issue 0014 / 0016 を含む）と実機を使い、ネイティブ RemoteIO のステレオ出力を検証した。

- `recvonly` と `sendrecv` を接続し、左右に異なる信号を入力した実際の出力で左右の分離を確認した。
- 切断後の再接続、割り込みからの復帰、出力経路の変更後もステレオ再生を確認した。
- マイク権限が未決定・拒否の状態で `recvonly` が接続でき、マイク入力を初期化しないことを確認した。
- `sendonly` / `sendrecv` ではマイク入力を初期化し、`initialMicrophoneEnabled` と `MediaChannel.setAudioHardMute(_:)` が動作することを確認した。
- Bluetooth HFP ではモノラル、A2DP ではステレオ出力となることを確認した。
- `DummyAudioDevice` は実機検証に代用せず、通常の CI にはマイク入力を必須とするテストを追加していない。

検証に利用した端末種別、OS、出力経路、category、mode、観測方法は検証時の記録に基づく。

### 2026-09-10 quickstart による追加検証

quickstart の実機ビルドを iPhone 13（iOS 26.6.1）へインストールし、Sora JavaScript SDK の `fake_stereo_audio` から同じチャンネルへ音声を送信した。

- 検証用の quickstart は `feature/zztkm-test` を `stereo-test` に rename したローカルブランチを使用した。検証時の基点コミットは `425b9ae017b15cb74cfacaf256361931c2d08716` である。このブランチは GitHub へは push していない。
- 音声送信側は `sora-js-sdk` の `feature/test-zztkm-add-stereo-audio-test-pattern` ブランチを使用した。`fake_stereo_audio` による左右音声パターンの変更はコミット `249302586233d2db543f8c1951524e7d4875e6a7` で、[GitHub のブランチ](https://github.com/shiguredo/sora-js-sdk/tree/feature/test-zztkm-add-stereo-audio-test-pattern) として参照できる。
- Sora iOS SDK `2026.3.0-canary.0` を含む Debug ビルドが成功し、アプリを USB 接続した iPhone 13 で起動できた。
- JavaScript 側はステレオを有効にし、左 440 Hz、右 660 Hz の音声を `both → left only → right only`（各 5 秒）で生成した。ブラウザー側の送信音声は 2 ch、観測周波数は左 445.3 Hz、右 656.3 Hz、ステレオ判定は `Yes` だった。
- iOS 側は `audioStereoOutputEnabled = true` の `sendrecv` 接続で、受信ストリームが追加され、画面に「ステレオ音声を受信中」と表示された。これは `RTCAudioTrackSink` で受信 PCM が 2 ch と判定されたことを示す。
- AudioSession は `playAndRecord` category と `default` mode を使用し、画面に表示された出力経路は受話口だった。接続は Debug 起動引数による自動接続で開始した。
- 接続中のアプリにクラッシュや接続エラーは発生しなかった。JavaScript 側の受信接続も維持され、送受信の接続が成立した。
- 初回実行時の iPhone の出力経路は受話口であり、その時点では物理的な左右分離の聴取確認は実施していなかった。
- その後、Bluetooth ヘッドホンへ出力を切り替え、実際のデバイスで左右で異なる音を聴取できることを確認した。Bluetooth 出力経路では物理的な左右分離を確認できた。
