# AudioOutput が期待通りに機能しているか確認する

- Priority: Low
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/investigate-audiooutput-behavior
- Polished:

## 概要

`AudioOutput` の設定（スピーカー出力またはデフォルト出力）が実際に機能しているかを確認し、期待するスピーカーの定義を明確にする。

## 背景

`AudioOutput` enum には `.default`（端末のデフォルト出力）と `.speaker`（スピーカー出力）が定義されているが、実際にこの設定が有効に機能しているかが未確認。また「スピーカー」が具体的に何を指しているのかも不明確な部分がある。

## 確認内容

- `AudioOutput.default` と `AudioOutput.speaker` を切り替えたときに出力先が変わるか確認する
- 「スピーカー」が `AVAudioSession` における `overrideOutputAudioPort(.speaker)` に相当するか確認する
- iPhone / iPad 双方で挙動を確認する
- イヤホン接続時の挙動も確認する

## 根拠

`AudioOutput` は SDK の公開 API として提供されているが、動作が保証されていない状態は利用者に誤解を与える。動作しない場合は修正または API の削除・変更を検討する必要がある。
