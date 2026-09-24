# Utilities.Stopwatch を非推奨にする

- Created: 2026-08-27
- Completed:
- Branch: feature/change-deprecate-stopwatch
- Polished: 2026-09-24

## 目的

リポジトリ内で利用されておらず、Timer lifecycle と executor 契約に問題がある公開 API `Utilities.Stopwatch` を非推奨にし、利用者へ移行方針と削除予定を明示する。

本 issue は非推奨化だけを扱い、削除は `0115` へ分離する。

## 現状

`Sora/Utilities.swift` の `Utilities.Stopwatch` は公開 API だが、SDK production code と test code に利用箇所がない。

現在の実装には次の問題がある。

- `Timer` closure が `self` を強参照し、`self` も Timer を保持する。
- `stop()` で invalidate した Timer を再利用するため、stop 後の `run()` が動作しない。
- `seconds`、`handler`、`timer` に同期がない。
- main RunLoop を使用するが、MainActor / main thread 契約がない。
- handler の実行 executor と reentrancy 契約がない。

Sora SDK の責務と関係しない一般 utility であり、Swift 6 対応のために新しい公開 abstraction を追加して維持する根拠がない。

ただし public API であるため、非推奨期間を設けずに削除すると downstream の source compatibility を壊す。

## 設計方針

- `Utilities.Stopwatch` を deprecated にする。
- deprecation message に、次期 major version で削除することを記載する。
- Sora SDK 固有の代替 timer API は追加しない。
- Foundation の Timer、Swift の Clock / Duration、アプリ側の MainActor timer など、用途に合う仕組みを利用者側で選ぶよう案内する。
- 単一の万能な置換先があるような説明をしない。
- 本 issue では API の実装、挙動、executor を変更しない。既存 lifecycle bug を修正する場合は bug category の別 issue とする。
- `0107` が提供した consumer package (`TestConsumers/Swift6Consumer/`) の `ConsumerLegacy` target
  (`Sources/ConsumerLegacy/DeprecatedAPI.swift`) に deprecated API の compile scenario を追加する。あわせて
  `.github/workflows/consumer-test.yml` の `Check Deprecation Warning` step が検査する非推奨 symbol 一覧へ
  `Stopwatch` を追加する (同 step のコメントが、`DeprecatedAPI.swift` の参照を増減する作業は一覧も
  同時に更新することを定めている)。非推奨 warning 以外の source break がないことを確認する。
- 公開 API baseline (`TestConsumers/Swift6Consumer/ApiBaseline/`) を同じ変更で再生成する。deprecation
  annotation は baseline の差分として現れるため、`CODEBASE.md` の baseline 更新手順に従い、差分の
  レビューも実施する。

## スコープ外

- `Utilities.Stopwatch` の削除は `0115` で扱う。
- Stopwatch の lifecycle bug 修正は別 issue とする。
- SDK 共通の timer abstraction は追加しない。
- `ConnectionTimer` は `0096` で扱う。
- `Utilities.swift` 内の他の API は変更しない。

## テスト方針

モックやスタブは使用しない。

- `TestConsumers/Swift6Consumer/` の `ConsumerLegacy` から `Utilities.Stopwatch` を従来どおり初期化・呼び出しできることを確認する。
- deprecated warning に削除予定と移行方針が表示されることを確認する (`consumer-test.yml` の `Check Deprecation Warning` が `Stopwatch` の symbol 名で検査する)。
- 再生成した公開 API baseline の差分を読み、deprecation annotation 以外の公開 API 変更がないことを確認する。
- テストには、非推奨期間を設ける理由を日本語コメントで明記する。

## 完了条件

- `Utilities.Stopwatch` が deprecated であること。
- deprecation message に削除時期と移行方針が記載されていること。
- 不要な代替 timer abstraction を追加していないこと。
- `Utilities.Stopwatch` のシグネチャと既存挙動を変更していないこと。
- consumer package で既存利用コードが compile できること。
- 公開 API baseline が再生成され、diff に意図しない変更がないこと (deprecation annotation の追加は意図した差分である)。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
