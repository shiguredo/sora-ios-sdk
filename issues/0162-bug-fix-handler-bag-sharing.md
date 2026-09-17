# Configuration の handlers bag が接続間で共有され、別接続の handler が発火する

- Created: 2026-09-17
- Completed:
- Priority: Low
- Branch: feature/fix-handler-bag-sharing
- Polished:

## 目的

1 つの `Configuration` から 2 つ以上の `MediaChannel` を作ると `MediaChannelHandlers` の bag が共有され、ある接続のために設定した handler が別の接続でも発火する問題を解消する。

## 現状

`Sora/Configuration.swift` の `mediaChannelHandlers` は可変 class の `MediaChannelHandlers` であり、`Configuration` は struct のため、値のコピーや再利用で同じ bag が共有される。

`Sora/MediaChannel.swift` の `MediaChannel.init` は `handlers = mediaChannelHandlers` で configuration の bag をそのまま公開 handlers に代入する。このため `MediaChannel.handlers` は接続ごとに独立した bag にならず、`mediaChannel.handlers.onDisconnect = ...` のような接続後の設定が、同じ configuration から作った他方の接続にも影響する。

`skills/sora-ios-sdk/SKILL.md` は `config.mediaChannelHandlers.onX = ...` という接続前の設定を案内しているが、`MediaChannel.handlers` が configuration の bag そのものであることは記載していない。`0154` は同じ参照代入を前提として handler property の読み書きの排他を扱うが、bag の共有自体は対象外である。

実機で次を確認した。

- samples の接続 A で `mediaChannel.handlers.onDisconnect` を設定した状態で、A の `Configuration` を値コピーして作った接続 B を切断すると、A の handler が発火する
- A の handler は接続の切断処理を呼ぶため、B の切断を契機に A まで切断される
- B に新しい `MediaChannelHandlers()` を設定すると解消する

## 再現手順

同一プロセスに 2 接続を作る。

1. 1 つ目の接続の `Configuration` から値コピーして 2 つ目の `Configuration` を作る (channelId など必要な項目だけ変更する)
2. 1 つ目の接続の `MediaChannel.handlers.onDisconnect` に、その接続を切断する処理を設定する
3. 2 つ目の接続を切断する
4. 1 つ目の handler が発火し、1 つ目の接続が切断される

## 設計方針

次のいずれかを実装時に決める。

- `MediaChannel.init` で configuration の bag をそのまま使わず、closure をコピーした接続ごとの bag を作る
- bag の共有を仕様として維持する場合、`Configuration.mediaChannelHandlers` と `MediaChannel.handlers` の doc および `skills/sora-ios-sdk/SKILL.md` に共有されることを明記し、接続ごとに変える場合は接続後に `handlers` へ新しい `MediaChannelHandlers` を代入する手順を示す

## 優先度根拠

複数接続を同一プロセスで使う具体的なユースケースが現時点で確認できていないため Low とする。発生した場合は無関係な接続が切断されるため、ユースケースが見つかった時点で優先度を見直す。

## 完了条件

- 同じ configuration から作った 2 接続で handler が互いに影響しないこと、または共有されることが doc に明記されていること
- 接続ごとに handler を設定する手段が公開 API として成立していること
- 2 接続で handler が交差しないことを検証するテストが追加されていること
- 追加したテストと既存テストがすべて成功すること

## 解決方法
