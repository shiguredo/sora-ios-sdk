# LogType.signaling のログがどの Logger.Group にも含まれず出力されない問題を修正する

- Created: 2026-09-18
- Completed:
- Priority: Medium
- Branch: feature/fix-signaling-log-output
- Polished: 2026-11-11

## 目的

`LogType.signaling` を指定したログが `Logger.Group` のどれにも含まれておらず、`level` / `groups` の設定に関係なく出力されない問題を修正する。

`Sora/Signaling.swift` の 3 箇所は「起きてはならない状態」を報告する INFO / WARN / ERROR ログであり、既定設定で出力されないと障害調査の材料が失われる。

## 現状

`Sora/Logger.swift` の `LogType` に `case signaling` (`description` は "Signaling") があるが、`Logger.output(log:)` の group 別 switch のどの受理リストにも `.signaling` が無く、`Logger.Group` にも `.signaling` に対応する case が無い。`.channels` は `.sora` / `.webSocketChannel` / `.signalingChannel` / `.peerChannel` / `.nativePeerChannel` / `.mediaChannel` / `.mediaStream` / `.dataChannel` / `.cameraVideoCapturer` / `.dummyAudioDevice` を受理する。

そのため `.signaling` のログは `groups` に何を設定しても `out` が false のままになり、`level` の設定にもよらず出力されない。

`type: .signaling` を使う箇所は `Sora/Signaling.swift` の 3 箇所で、いずれも異常系である。

- `serializeData(_:)` の downcast 失敗 (`Logger.info`)
- `updateMetadata(signaling:data:)` の JSON デコード失敗の catch (`Logger.error`)
- `SignalingOffer.Encoding` の `init(from:)` の `default:` (未知の networkPriority) (`Logger.warn`)

`0106` は filtering の受理リストを変更しておらず、本問題は `0106` の変更前から develop に存在する。

## 前提となる issue

- `0106` (完了・develop にマージ済み): Logger の共有可変状態の同期。`Logger.output(log:)` の filtering と masking は変更していないが、同じ `Sora/Logger.swift` を変更するため `0106` のマージ後に着手する。

## 設計方針

- `.channels` の受理リストに `.signaling` を追加する。1 行の追加で済み、公開 enum `Logger.Group` の case を増やさないため公開 API の追加・変更が無い (変わるのはログの出力内容だけである)。
- `.signaling` は `.signalingChannel` とは別の case で `description` も異なる。`Sora/Signaling.swift` のファイルスコープ関数と Codable のデコードで使われているため、`.signalingChannel` へ置き換えず `.channels` で受理する。
- `LogType.signaling` の削除は行わない (公開 enum の case 削除は source compatibility に影響し、本問題の修正には不要)。
- `.channels` に `.signaling` を追加すると `serializeData(_:)` の downcast 失敗ログが既定設定で出力されるようになる。`.signaling` を有効化したまま従来のメッセージ組み立て (`String(describing: data)`) を残すと、Foundation の辞書・配列の description (plist 形式の `"key" = value;`) は `Logger.maskSecrets` の対象 (JSON の `"key":"value"`) にならず、`authn_metadata` / `authz_metadata` / `metadata` に含まれるマスク対象キーの文字列値が平文で残る。データを `JSONSerialization` で JSON に戻してから出力し、既存のマスクが効く形式に揃える。
- `JSONSerialization.data(withJSONObject:)` は `-1e999` を解析した `-inf` のような JSON の数値として表現できない値を渡すと捕捉できない NSException を送出するため、直列化の前に `isValidJSONObject` で検証する。JSON に戻せない値はデータ本体を出力せず、`<not a JSON value>` とだけ出力する。
- ログのマスク対象は `Logger.maskSecrets` の対象キーの文字列値のみで、それ以外のキーと値は平文で出力される。これは既存のログのマスク方針と同じであり、本 issue ではマスクの対象を広げない。
- 既定設定 (`level = .info`、`groups = [.channels, .user]`) でも現状では出力されない 3 箇所が出力されるようになる後方互換な変更として `CHANGES.md` の `[FIX]` に記載する。

## 変更対象

- `Sora/Logger.swift`: `Logger.output(log:)` の `.channels` の受理リストに `.signaling` を追加する
- `Sora/Signaling.swift`: `serializeData(_:)` の downcast 失敗ログを、受信データを検証してから JSON に戻して出力する形へ変更する
- `SoraTests/LoggerTests.swift`: filtering のテストに `.signaling` のケースを追加する
- `SoraTests/SecretMaskingTests.swift`: 既定設定で downcast 失敗ログが出力され、マスク対象キーの文字列値が平文で含まれないことを検証するテストを追加する
- `SoraTests/LoggerCapture.swift`: 出力された `Log` の一覧を返す accessor を追加する
- `SoraTests/StringCollector.swift`: `LoggerCapture` からの利用が無くなったため、その旨のコメントを修正する
- `CHANGES.md`: `## develop` の主リストの `[FIX]` にエントリを追記する

## テスト方針

モックやスタブは使用しない。

- `groups = [.channels]` / `level = .info` で `type: .signaling` の `Log` が handler に届くこと
- `groups = [.user]` と `groups = []` では届かないこと (他の `.channels` の type と同じ扱いであること)
- `Signaling.decode(_:)` に `data` がオブジェクトの配列でない notify を渡し、既定設定で downcast 失敗ログが出力され、`access_token` / `username` の文字列値が平文で含まれないこと
- `data` が JSON の断片 (文字列) の場合、オブジェクトの場合、JSON の数値として表現できない値を含む場合に、クラッシュせずログが出力されること
- 出力の有無はユニットテストで判定できるため実機確認は不要

## 完了条件

- `Logger.output(log:)` の受理リストに `.signaling` が含まれ、`groups` に `.channels` を含む設定で `.signaling` のログが出力されること
- `SoraTests/LoggerTests.swift` の filtering のテストが `.signaling` を検証し、成功すること
- `serializeData(_:)` の downcast 失敗ログが、JSON に戻せるときは JSON 形式で出力され、マスク対象キーの文字列値が平文で含まれないこと
- `data` が JSON に戻せない値でもクラッシュせず、データ本体を出力しないこと
- `CHANGES.md` の `## develop` へ `[FIX]` が追記されていること
- 追加したテストと既存テストがすべて成功すること

## 解決方法
