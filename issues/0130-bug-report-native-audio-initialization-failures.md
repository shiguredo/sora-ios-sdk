# ネイティブ音声の初期化失敗を対象の接続へ通知する

- Created: 2026-09-07
- Completed: {YYYY-MM-DD}
- Branch: feature/add-stereo-audio-output
- Polished: {YYYY-MM-DD}

## 目的

ネイティブ音声の初期化に失敗した際、SDK 利用者が失敗した接続と原因を識別できるようにする。

## 現状

調査対象は PR #381 のコミット `16cba6346931d9d631e7061cb5632d193c1a2cb8` と libwebrtc `m150.7871.3.2` である。

- `NativePeerChannelFactory` は `setStereoPlayoutEnabled` の戻り値を検査するが、この呼び出しは後で行う AudioUnit の初期化成功を保証しない。
- webrtc-build の `AudioDeviceIOS::InitPlayOrRecord` は AudioUnit の初期化結果を確認せず、成功を返す経路がある。
- `SoraRTCAudioSessionDelegateAdapter` は経路変更を中継するが、音声初期化の失敗を対象の接続へ通知する仕組みはない。
- 現在のソフトウェア経路のテストだけでは、実機の AudioUnit 初期化失敗を検証できない。

無音になる特定の端末条件は未検証であり、コード上のエラー伝播の欠落を根拠とする issue である。

## 設計方針

- webrtc-build issue 0011 の修正を含むビルドを取り込み、ADM と対応付いた初期化失敗を受け取る。
- 接続完了前に検知した失敗は接続処理の失敗として扱う。接続完了後の失敗は既存の切断・エラー通知の契約に従い、成功済みの完了ハンドラを再度呼ばない。
- 失敗と切断が競合しても、対象の通知とリソース解放を重複させない。
- 共有 AudioSession の通知から、失敗と無関係な MediaChannel を一律に切断しない。
- 失敗後は PeerConnection、ADM、AudioSession の利用要求を適切な順序で解放し、次の接続を開始できるようにする。
- 一般的な AudioSession イベントの公開を扱う既存 issue 0035 とは目的を分ける。共通の通知経路を使う場合は両者の責務を揃える。

## 対応ブランチと依存関係

ユーザー指定の例外として、PR #381 の `feature/add-stereo-audio-output` に含める。
webrtc-build の `feature/m150.7871` で issue 0011 を先に対応し、その成果物を取り込んでから実装する。
取り込み時には `Package.swift` のバージョンと checksum、`WebRTCInfo` の情報を揃える。

## テスト方針

既存の接続・切断テストと実際の ADM を使い、通知の回数、接続状態、解放後の再接続を確認する。
実機でしか発生させられない初期化失敗は手動検証とし、手順と結果を残す。
モックやスタブは使用しない。

## 完了条件

- ネイティブ音声の初期化失敗を、失敗した接続の利用者が検知できる。
- 接続完了の前後と切断との競合で、通知と解放が既存の契約に従う。
- 失敗した接続の後で、新しい接続を開始できる。
- 失敗と無関係な接続を誤って切断しない。
- 正常な mono / stereo 接続の動作を維持する。
- 依存ビルドと検証結果、および未検証の条件が記録されている。

## 解決方法
