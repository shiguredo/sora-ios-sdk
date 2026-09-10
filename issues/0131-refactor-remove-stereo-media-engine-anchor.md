# stereo 設定維持用の未接続 PeerConnection を削除する

- Created: 2026-09-07
- Completed: {YYYY-MM-DD}
- Branch: feature/add-stereo-audio-output
- Polished: {YYYY-MM-DD}

## 目的

stereo 設定を維持するためだけに保持している PeerConnection を不要にし、ネイティブ音声の生成と解放を簡潔にする。

## 現状

調査対象は PR #381 のコミット `16cba6346931d9d631e7061cb5632d193c1a2cb8` と libwebrtc `m150.7871.3.2` である。

- `NativePeerChannelFactory` は stereo の場合に `stereoMediaEngineAnchor` として未接続の PeerConnection を保持する。
- MediaEngine の利用数が 0 になった後の ADM 再初期化で stereo 設定が失われるため、PeerConnectionFactory の保持だけでは足りない。
- 現在はこの anchor の生成失敗も処理する必要があり、終了時は anchor を閉じてから AudioSession の利用要求を解放する。
- SDK 側だけで anchor を取り除くと、設定を維持する前提が崩れる。

## 設計方針

- webrtc-build issue 0012 によって ADM 自身が設定を保持するビルドを取り込んだ後、anchor と、そのためだけの生成・失敗・解放処理を削除する。
- one-time offer、通常の接続、リダイレクトを含め、実際の PeerConnection の利用数が 0 になる遷移を確認する。
- PeerConnection を閉じてから AudioSession の利用要求を解放し、その後に利用者へ完了を通知する順序を維持する。
- anchor の存在を確認するテストは、再初期化後も設定が維持されるという利用者に必要な性質の検証へ変更する。

## 対応ブランチと依存関係

ユーザー指定の例外として、PR #381 の `feature/add-stereo-audio-output` に含める。
webrtc-build の `feature/m150.7871` で issue 0012 を先に対応する。
依存ビルドの取り込みは issue 0130 と調整し、バージョン、checksum、`WebRTCInfo` を一致させる。

## テスト方針

実際の ADM、PeerConnectionFactory、PeerConnection を使って、接続準備から終了と再接続までを検証する。
通常の mono と stereo の両方を含め、モックやスタブは使用しない。
実機の左右の再生確認は issue 0134 で行う。

## 完了条件

- `stereoMediaEngineAnchor` と、それだけのために存在する処理が削除されている。
- PeerConnection の利用数が 0 になってから再生成しても、stereo 出力設定が維持される。
- one-time offer とリダイレクトを経た接続が、意図した設定で動作する。
- 接続失敗、通常の切断、再接続で AudioSession の利用要求が残らない。
- 通常の mono 接続と、切断後の通知・解放の順序を維持する。

## 解決方法
