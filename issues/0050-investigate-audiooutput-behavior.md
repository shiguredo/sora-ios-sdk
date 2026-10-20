# AudioOutput が期待通りに機能しているか確認する

- Priority: Low
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/investigate-audiooutput-behavior
- Polished: 2026-09-23

## 概要

`AudioOutput` の設定（スピーカー出力またはデフォルト出力）が実際に機能しているかを実機で確認し、期待するスピーカーの定義を明確にする。

## 背景

`AudioOutput` enum は `Sora/AudioMode.swift` に定義され、`AudioMode.default(category:output:)` と `AudioMode.voiceChat(output:)` の関連値として、`Sora/Sora.swift` の `setAudioMode` で使用される（`AudioMode.videoChat` は `AudioOutput` を持たず、スピーカー出力固定である）。

`AudioOutput` には `.default`（端末のデフォルト出力）と `.speaker`（スピーカー出力）が定義されているが、実際にこの設定が有効に機能しているかが未確認。また「スピーカー」が具体的に何を指しているのかも不明確な部分がある。

現行実装の `setAudioMode` における `.speaker` の扱いは次のとおりである。

- `AudioMode.default(category:output: .speaker)`: `.defaultToSpeaker` カテゴリオプションのみを追加し、`overrideOutputAudioPort` は呼ばない
- `AudioMode.voiceChat(output: .speaker)`: `.defaultToSpeaker` オプションに加えて `overrideOutputAudioPort(.speaker)` を呼ぶ
- `output: .default`: `.defaultToSpeaker` を付けず、`overrideOutputAudioPort(.none)` で出力経路をリセットしてから設定する

このため「スピーカーが `AVAudioSession` における `overrideOutputAudioPort(.speaker)` に相当する」という理解は現行実装と一致しない。`AudioOutput.default` のドキュメントコメントは「デフォルト。端末の状態に依存します。」とあるが、`.speaker` との挙動の違いは明確ではない。

## 確認内容

- `AudioMode.default` と `AudioMode.voiceChat` のそれぞれで、`AudioOutput.default` と `AudioOutput.speaker` を切り替えたときに出力先が変わるか確認する
- 「スピーカー」が何を指すのかを確認する。`.defaultToSpeaker` と `overrideOutputAudioPort(.speaker)` のそれぞれが、どのカテゴリ・どの出力経路（内蔵スピーカー、受話口、イヤホン、Bluetooth）で有効かを分類する
- iPhone / iPad 双方で挙動を確認する
- イヤホン接続時（有線・Bluetooth）の挙動も確認する。イヤホン接続中に `.speaker` を指定した場合、内蔵スピーカーへ戻るのかイヤホンのままかを記録する

## 完了条件

- `AudioMode.default` / `AudioMode.voiceChat` で `.default` / `.speaker` を切り替えたときの出力経路の変化が、iPhone / iPad のそれぞれとイヤホン未接続 / 接続（有線・Bluetooth）の条件で確認され、端末種別、OS、出力経路名とともに記録されている
- 「スピーカー」の定義（内蔵スピーカーを指すのか、有効になるカテゴリ・出力経路の条件）が確定し、本 issue 内に記録されている（必要に応じて `AudioMode` / `AudioOutput` のドキュメントコメントや利用ガイドへ反映する）
- 機能しない場合、実装の修正または `AudioOutput` の API 定義の見直し（削除・変更・ドキュメントでの制約明記）の結論が記録されている

## 根拠

`AudioOutput` は SDK の公開 API として提供されているが、動作が保証されていない状態は利用者に誤解を与える。動作しない場合は修正または API の削除・変更を検討する必要がある。
