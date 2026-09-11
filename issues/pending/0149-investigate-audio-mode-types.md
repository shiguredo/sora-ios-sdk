# AudioMode の種類を増やすべきか検討する

- Created: 2026-09-11
- Completed: {YYYY-MM-DD}
- Branch: feature/investigate-audio-mode-types
- Polished: {YYYY-MM-DD}

## 目的

`AudioMode` は用途ごとの音声設定を選びやすくするためのものだが、受信専用など一部の用途に合う種類がなく、`.default` で個別に設定する必要がある。どのような種類を用意すべきかを検討する。

## 現状

`AudioMode` には次の 3 種類しかない。

- `.default(category:output:)`
- `.videoChat`
- `.voiceChat(output:)`

受信専用の設定を行う場合、`.default` を使って音声カテゴリと出力先を個別に指定する必要があり、用途に合った種類が用意されていない。

また `AudioMode` のドキュメントコメントは、詳細な設定を行いたい場合に `AVAudioSession` を使用するよう案内している。`Sora.configureAudioSession(block:)` は用意されているが、`AVAudioSession` を直接操作する方法が適切かは見直しの余地がある。

## 設計方針

- 受信専用やオーディエンスなど、追加すべき `AudioMode` の種類と、その音声カテゴリ・モード・オプションを整理する
- 種類を増やす方針と、詳細なカスタマイズ方法を `RTCAudioSession` 経由でドキュメントに案内する方針を比較検討する
- ハンズフリー用途も視野に入れて検討する
- `AudioMode` のドキュメントコメントが案内している `AVAudioSession` の直接利用が適切かを見直す

## pending にした理由

どのような種類を用意すべきか、また種類を増やす方針とドキュメントでカスタマイズ方法を案内する方針のどちらを取るかについて議論が必要で、結論が出ていないため pending とする。

## 解決方法

## Pending 解除条件

- 追加する `AudioMode` の種類（受信専用・オーディエンスなど）と、種類を増やすかドキュメント誘導にするかの方針を決定する。
- 決定した方針を `AudioMode` の実装またはドキュメントに反映する。
