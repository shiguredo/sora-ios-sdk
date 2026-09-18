# LogType.signaling のログがどの Logger.Group にも含まれず出力されない問題を修正する

- Created: 2026-09-18
- Completed:
- Priority: Medium
- Branch: feature/fix-signaling-log-output
- Polished:

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

実機の `.debug` ログ (11,364 行) にも `Signaling` タイプの行は 1 件も無いが、上記 3 箇所は異常系のため発火していない可能性がある。根拠は filtering のコードにある。

`0106` は filtering の受理リストを変更しておらず、本問題は `0106` の変更前から develop に存在する。

## 前提となる issue

- `0106` (完了・develop にマージ済み): Logger の共有可変状態の同期。`Logger.output(log:)` の filtering と masking は変更していないが、同じ `Sora/Logger.swift` を変更するため `0106` のマージ後に着手する。

## 設計方針

- `.channels` の受理リストに `.signaling` を追加する。1 行で完結し、公開 enum `Logger.Group` の case を増やさないため公開 API の追加・変更が無い (変わるのはログの出力内容だけである)。
- `.signaling` は `.signalingChannel` とは別の case で `description` も異なる。`Sora/Signaling.swift` のファイルスコープ関数と Codable のデコードで使われているため、`.signalingChannel` へ置き換えず `.channels` で受理する。
- `LogType.signaling` の削除は行わない (公開 enum の case 削除は source compatibility に影響し、本問題の修正には不要)。
- 既定設定 (`level = .info`、`groups = [.channels, .user]`) でも上記 3 箇所が出力されるようになる後方互換な変更として `CHANGES.md` の `[FIX]` に記載する。

## 変更対象

- `Sora/Logger.swift`: `Logger.output(log:)` の `.channels` の受理リストに `.signaling` を追加する
- `SoraTests/LoggerTests.swift`: filtering のテストに `.signaling` のケースを追加する
- `CHANGES.md`: `## develop` の主リストの `[FIX]` にエントリを追記する

## テスト方針

モックやスタブは使用しない。

- `groups = [.channels]` / `level = .info` で `type: .signaling` の `Log` が handler に届くこと
- `groups = [.user]` と `groups = []` では届かないこと (他の `.channels` の type と同じ扱いであること)
- 出力の有無はユニットテストで判定できるため実機確認は不要

## 完了条件

- `Logger.output(log:)` の受理リストに `.signaling` が含まれ、`groups` に `.channels` を含む設定で `.signaling` のログが出力されること
- `SoraTests/LoggerTests.swift` の filtering のテストが `.signaling` を検証し、成功すること
- `CHANGES.md` の `## develop` へ `[FIX]` が追記されていること
- 追加したテストと既存テストがすべて成功すること

## 解決方法
