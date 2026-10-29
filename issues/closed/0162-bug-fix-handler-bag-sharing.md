# Configuration の MediaChannelHandlers が接続間で共有され、別接続の handler が発火する

- Created: 2026-09-17
- Completed: 2026-10-29
- Priority: Low
- Branch: feature/fix-handler-bag-sharing
- Polished: 2026-10-29
- Updated: 2026-10-29

## 目的

1 つの `Configuration` から 2 つ以上の `MediaChannel` を作ると `MediaChannelHandlers` の bag が共有され、ある接続のために設定した handler が別の接続でも発火する問題を解消する。本 issue は `MediaChannelHandlers` を対象とし、`Configuration.webSocketChannelHandlers` の同型の共有は対象外とする。

## 現状

`Sora/Configuration.swift` の `mediaChannelHandlers` は可変 class の `MediaChannelHandlers` であり、`Configuration` は struct のため、値のコピーや再利用で同じ bag が共有される。

`Sora/MediaChannel.swift` の `MediaChannel.init` は `handlers = mediaChannelHandlers` で configuration の bag をそのまま公開 handlers に代入する。`MediaChannel.handlers` は `0154` (2026-10-02 closed) で `HandlerStorage<MediaChannelHandlers>` の lock 付きアクセサになったが、保持するのは init で受け取った instance そのものである。`HandlerStorage.current` は参照型では同じ instance を返すため、bag の handler property の変更は `Configuration.mediaChannelHandlers` と `MediaChannel.handlers` の両方に反映される。このため `MediaChannel.handlers` は接続ごとに独立した bag にならず、`mediaChannel.handlers.onDisconnect = ...` のような接続後の設定が、同じ configuration から作った他方の接続にも影響する。

`skills/sora-ios-sdk/SKILL.md` は `config.mediaChannelHandlers.onX = ...` という接続前の設定を案内している。handler 設定の読み書きが SDK 内部の lock で排他されること (`0154`) は記載しているが、`MediaChannel.handlers` が configuration の bag そのものであることは記載していない。`0154` は `MediaChannelHandlers` の各 handler property と `MediaChannel.handlers` の参照差し替えを排他したが、bag の共有自体は対象外である。

`Configuration.webSocketChannelHandlers` にも同じ参照共有がある。`SignalingChannel` は init で `webSocketChannelHandlers` を保持し、`setUpWebSocketChannel(url:proxy:caCertificates:)` で `ws.handlers` へ参照を代入する。`SignalingChannel` の `webSocketChannelHandlers` property の doc は「snapshot には含めず、参照のまま受け取ります」と明記している。接続前に `Configuration` のコピーへ接続ごとの bag を設定することはできるが、接続開始後に bag を差し替える公開 API はなく、`MediaChannel.configuration` 経由の in-place 変更は接続中の WebSocket にも影響する。本 issue では `MediaChannelHandlers` に限定し、WebSocket 側は別のスコープ判断として扱う。

次の現象が起きる。共有経路は現行コードの `MediaChannel.init` と `HandlerStorage` の参照保持で確認できる。

- 接続 A で `mediaChannel.handlers.onDisconnect` を設定した状態で、A の `Configuration` を値コピーして作った接続 B を切断すると、A の handler が発火する
- A の handler は接続の切断処理を呼ぶため、B の切断を契機に A まで切断される
- B に新しい `MediaChannelHandlers()` を設定すると解消する

リポジトリ内の既存コードと closed issue には、この共有を前提にしているものと、共有を避ける回避策を取っているものがある。

- `SoraTests/SoraEventE2ETests.swift` の `testTwoConnectionsDeliverStreamAndDataChannelEventsWithoutMixing` は、handler bag を接続間で共有しないよう 2 接続目の `Configuration` を組み立て直している
- `SoraTests/RpcE2ETests.swift` の `waitForDisconnectCompletion` は、共有される `MediaChannelHandlers` を前提に待ち終了時に `channel.handlers.onDisconnect = nil` で外している
- `0190` (2026-10-16 closed) は、同じ `Configuration` から作ったチャンネル間で `MediaChannelHandlers` が共有されることを前提に、待ちで設定した handler の後始末を説明している
- `0195` (2026-10-27 closed) は、同じ前提で、接続前に登録した handler が接続前の signaling を取り逃さないことを説明している

## 再現手順

同一プロセスに 2 接続を作る。

1. 1 つ目の接続の `Configuration` から値コピーして 2 つ目の `Configuration` を作る (channelId など必要な項目だけ変更する)
2. 1 つ目の接続の `MediaChannel.handlers.onDisconnect` に、その接続を切断する処理を設定する
3. 2 つ目の接続を切断する
4. 1 つ目の handler が発火し、1 つ目の接続が切断される

## 設計方針

接続ごとの bag をコピーする方針に確定する。

- `MediaChannelHandlers` に internal なコピー用イニシャライザを追加し、10 個の handler property (deprecated の `onDisconnectLegacy` / `onReceiveSignaling` を含む) を 1 つずつ写す。コピーは designated init (`init(snapshot:configuration:audioDevice:mediaChannelHandlers:webSocketChannelHandlers:...)`) の `handlers` への代入箇所で行う (`handlers = MediaChannelHandlers(copying: mediaChannelHandlers)` のようにコピー後の値を設定する)。`Sora.connect` は designated init を直接呼ぶため、convenience init だけにコピーを入れると利用者経路に効かない
- コピー用イニシャライザは internal に閉じるため公開 API は変更しない。`TestConsumers/Swift6Consumer/ApiBaseline/` の再生成は不要である
- `0102` は「引き渡すのは handler bag の参照であり、closure を copy しない」と決めていた。本 issue は接続間の混線 (別接続の切断) を優先し、configuration 側の bag だけを接続開始時にコピーする。`0102` が守った「接続開始後の handler 変更が次の配送から反映される」は、`MediaChannel.handlers` の bag 差し替え (`mediaChannel.handlers = ...`) と handler property の設定 (`mediaChannel.handlers.onDisconnect = ...`) の両方で維持する
- signaling 開始前に handler を効かせる必要がある場合は、`SoraHandlers.onAddMediaChannel` の中で `mediaChannel.handlers` を設定する (`MediaChannel.connect` が `.connecting` へ遷移した後、非同期の `basicConnect` より前に呼ばれる)。接続完了後に設定すると、接続完了より前に届く offer / switched を取り逃す (`0195` と同じ理由)。bag 全体を差し替えると configuration からコピーした handler は引き継がれないため、doc では bag の差し替えと handler property の設定を書き分ける
- 影響: 接続開始後に `Configuration.mediaChannelHandlers` の handler property を変更しても、接続済みの `MediaChannel.handlers` には反映されない。この配送セマンティクスの変更は `0110` の完了条件に従い、`Configuration.mediaChannelHandlers` と `MediaChannel.handlers` の doc および `skills/sora-ios-sdk/SKILL.md` の「コールバックのスレッド」節に記載し、`CHANGES.md` の `## develop` で `[CHANGE]` とする

## 変更対象

- `Sora/MediaChannel.swift`: `MediaChannelHandlers` の internal なコピー用イニシャライザ、designated init でのコピー設定、`handlers` doc への接続ごとの設定方法 (bag の差し替えと handler property の設定の違い) の追記
- `Sora/Configuration.swift`: `mediaChannelHandlers` の doc に、接続開始時にコピーされることと接続後の変更が反映されないことを追記する
- `skills/sora-ios-sdk/SKILL.md`: 「コールバックのスレッド」節と接続の流れに、接続前登録と接続ごとの設定方法を追記する
- `SoraTests/`: コピー用イニシャライザの全 property コピー、2 接続の handler 分離、接続前登録の維持、接続後の `MediaChannel.handlers` 設定の反映、`Sora.connect` 経由のコピーを検証するテスト
- `SoraTests/RpcE2ETests.swift` と `SoraTests/SoraEventE2ETests.swift`: 共有を前提にしたコメントを現状に合わせる
- `CHANGES.md`: `## develop` に挙動変更を `[CHANGE]` で追記する

## 優先度根拠

複数接続を同一プロセスで使う利用者アプリのユースケースは現時点で確認できていないため Low とする (リポジトリ内の E2E テストは 2 接続を同一プロセスで張っており、現状に記載した回避策と共有依存がある)。発生した場合は無関係な接続が切断されるため、ユースケースが見つかった時点で優先度を見直す。

## 完了条件

- designated init (`MediaChannel.init(snapshot:configuration:audioDevice:mediaChannelHandlers:webSocketChannelHandlers:...)`) が configuration の bag をコピーした接続ごとの `MediaChannelHandlers` を `handlers` に設定していること
- コピー用イニシャライザが 10 個すべての handler property (deprecated を含む) を写すことを検証するテストが追加されていること
- 同じ `Configuration` から作った 2 接続で、一方の `MediaChannel.handlers` に設定した handler が他方の接続のイベントで発火しないこと (2 接続で handler が交差しないこと) を検証するテストが追加されていること
- `MediaChannel` の生成前 (`Sora.connect` の呼び出し前) に `Configuration.mediaChannelHandlers` へ登録した handler がコピーされて両方の接続の配送で呼ばれること (接続前登録の維持) を検証するテストが追加されていること
- 接続開始後に `MediaChannel.handlers` の handler property を設定した handler が次の配送から反映されること (`0102` が守った接続後の設定手段の維持) を検証するテストが追加されていること
- `Sora.connect` 経由で作った接続でも configuration の bag がコピーされていることを検証するテストが追加されていること
- 上記 5 つのテストは `SoraTests` の unit test とし、モックやスタブを使わない。コピー用イニシャライザのテストと `Sora.connect` 経由のテスト以外は、同一 `Configuration` から 2 つの `MediaChannel` を作り、`connect` で `.connecting` にしてから `disconnect(error:)` を呼んで `handlers.onDisconnect` の配送を駆動する (`SoraTests/StereoAudioOutputTests.swift` の `testMediaChannelDisconnectFinishesAfterOperationEnds` が `connect` してから `disconnect(error:)` で駆動している。生成直後の `MediaChannel` は `.disconnected` のため、`connect` せずに `disconnect` を呼んでも `onDisconnect` は配送されない)。`Sora.connect` 経由のテストは 1 接続で `handlers` が configuration の bag と異なることを確認する
- `Configuration.mediaChannelHandlers` と `MediaChannel.handlers` の doc に、接続開始時にコピーされること、接続後の configuration 側の変更が反映されないこと、接続ごとの設定方法 (`SoraHandlers.onAddMediaChannel` での `handlers` の設定。bag の差し替えと handler property の設定の違いを含む) が記載されていること
- `skills/sora-ios-sdk/SKILL.md` の「コールバックのスレッド」節と接続の流れに同じ内容が記載されていること
- `CHANGES.md` の `## develop` に挙動変更が追記されていること (種別は `shiguredo-changelog` に従う)
- 共有を前提にしたテストのコメントが現状に合っていること
- 追加したテストと既存テストがすべて成功すること

## 解決方法

`MediaChannelHandlers` に internal なコピー用イニシャライザ `init(copying:)` を追加し、`MediaChannel` の designated init で `Configuration.mediaChannelHandlers` を接続ごとにコピーして `handlers` に設定するようにした。deprecated の `onDisconnectLegacy` / `onReceiveSignaling` を含む 10 個の handler property を写し、deprecated の参照は非推奨警告を増やさないよう private storage から行う。コピー用イニシャライザは internal に閉じるため公開 API は変わらず、公開 API baseline の再生成は不要である。

- `Sora/MediaChannel.swift`: コピー用イニシャライザを追加し、designated init で `Configuration` の bag をコピーして `handlers` に設定する。`MediaChannelHandlers` / `MediaChannel.handlers` の doc に、接続ごとの独立、接続開始後に `Configuration` 側を変更しても接続済みの配送に反映されないこと、`SoraHandlers.onAddMediaChannel` での設定、bag 全体の差し替えと handler property 設定の違いを記載する。`onConnect` の doc は、接続試行の終了時 (成功時は `nil`、接続成立前の切断・接続失敗時はエラー) に修正する
- `Sora/Configuration.swift`: `mediaChannelHandlers` の doc に、接続開始時のコピー、接続後の変更が接続済みの配送に反映されないこと、`MediaChannel.configuration.mediaChannelHandlers` 経由の変更も反映されないことを追記する
- `Sora/Sora.swift`: `SoraHandlers.onAddMediaChannel` の doc に、呼ばれるタイミングと接続ごとの handler 設定の用途を追記する
- `skills/sora-ios-sdk/SKILL.md`: 「接続の流れ」と「コールバックのスレッド」節、`MediaChannelHandlers` 節に同じ内容を記載する。`configuration` の説明に `MediaChannel.configuration.mediaChannelHandlers` 経由の変更が配送に反映されないことを、「切断イベント」の例が接続の開始前の設定であること (接続ごとなら `MediaChannel.handlers.onDisconnect` を使うこと) を追記する
- `SoraTests/MediaChannelHandlersTests.swift`: コピー用イニシャライザの全 property コピー、2 接続の handler 分離、接続前登録の維持、接続後の `MediaChannel.handlers` 設定の反映、`Sora.connect` 経由のコピーを検証する 5 つの unit test を追加する (モック・スタブ不使用)
- `SoraTests/RpcE2ETests.swift` / `SoraTests/SoraEventE2ETests.swift`: 共有を前提にしたコメントを現状に合わせて更新する。`waitForDisconnectCompletion` では、共有 bag を前提にしていた不要な `defer { channel.handlers.onDisconnect = nil }` を削除する
- `CHANGES.md`: `## develop` に `[CHANGE]` として、接続開始後に configuration 側で handler を変更しても接続済みの接続へ反映されない挙動変更と、移行時の注意 (`MediaChannel.handlers` が同じ instance でなくなること、接続の完了前に届くイベントを受け取る handler の設定先) を追記する

確認したこと:

- `make fmt-lint` と SwiftLint strict が成功する
- シミュレータで全 unit test が成功する (543 tests / 0 failures。スキップ 39 件の内訳は、E2E の環境変数未設定 32 件、シミュレータに実カメラが無いこと 6 件、シミュレータでは実行しない共有 AudioSession の経路 1 件)
- 実機向け Release ビルド (warnings-as-errors) が成功する

E2E と TSan は CI で確認する。公開 API は変えていないため API baseline は変更しない。
