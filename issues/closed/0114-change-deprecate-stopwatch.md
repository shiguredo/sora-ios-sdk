# Utilities.Stopwatch を非推奨にする

- Created: 2026-08-27
- Completed: 2026-09-29
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

`Sora/Utilities.swift` の `Utilities.Stopwatch` に `@available(*, deprecated, message: ...)` を付け、削除予定時期と用途別の移行方針を利用者へ示した。実装、シグネチャ、観測可能な挙動は変更しておらず、`StopwatchStorage` / `PairTable` / `Optional.unwrap(ifNone:)` / `Utilities.randomString` の挙動も変えていない。`Stopwatch` に `Sendable` 準拠は追加していない。

### 付けた annotation と message

`Utilities.Stopwatch` の型宣言の直前に付けた。message の全文は次のとおり。

```
2027 年中に廃止予定です。
1 秒ごとに経過時間を handler へ通知するカウンタであり、Sora SDK 固有の機能ではないため、用途に合う仕組みを選んでください。
1 秒ごとの定期実行や表示の更新には、Foundation の Timer を MainActor 上のタイマーとして管理するか、Swift の ContinuousClock と Task.sleep(for:) を組み合わせてください。
経過時間の計測だけが目的であれば、ContinuousClock や SuspendingClock の now の差分 (Duration) を利用してください。
Sora SDK 固有の代替 timer は提供しません。
```

削除予定時期は `ICEServerInfo.tlsSecurityPolicy` / `TLSSecurityPolicy` / `Configuration.spotlightEnabled` などの既存の非推奨 API と同じ `YYYY 年中に廃止予定` 形式に合わせ、`2027 年中に廃止予定です。` とした。`0115` の前提が求める形式 (`YYYY 年中に廃止予定` または次期 major version) を満たす。

移行方針は用途別に書いた。1 秒ごとの定期実行や表示の更新は Foundation の `Timer` を MainActor 上のタイマーとして管理する方法か `ContinuousClock` と `Task.sleep(for:)` の組み合わせ、経過時間の計測だけなら `ContinuousClock` / `SuspendingClock` の `now` の差分 (`Duration`) とした。単一の万能な置換先があるような説明はせず、SDK 固有の代替 timer も追加していない。`Stopwatch` は 1 秒ごとに経過時間を `"時:分:秒"` で handler へ通知するカウンタであり、この用途ごとの移行先を message と `CHANGES.md` の両方に書いている。

### consumer と workflow の更新

- `TestConsumers/Swift6Consumer/Sources/ConsumerLegacy/DeprecatedAPI.swift`: `makeLegacyStopwatch()` を追加し、`Utilities.Stopwatch(handler:)` の初期化と `run()` / `stop()` の呼び出しが deprecation warning だけで compile できることを検証する。非推奨期間を設ける理由 (公開 API であり、期間を設けずに削除すると利用側の source compatibility が壊れる) は日本語コメントで明記した。
- `.github/workflows/consumer-test.yml`: `Check Deprecation Warning` が検査する symbol 一覧の先頭 (ASCII 昇順) に `'Stopwatch'` を追加した。実際に `ConsumerLegacy` の build log に出た warning は `'Stopwatch' is deprecated: 2027 年中に廃止予定です。` の 1 種類だけで、`init(handler:)` / `run()` / `stop()` には deprecation warning が出なかったため、追加した symbol は `Stopwatch` だけである。
- `CHANGES.md`: `## develop` の `[CHANGE]` 群の末尾に、非推奨化、2027 年中の廃止予定、用途別の移行案内、担当者行 `- @t-miya` を持つエントリを追加した。issue 番号は書いていない。
- `skills/sora-ios-sdk/SKILL.md`: 本 issue は「非推奨 API」表の更新を変更対象に含めていない (`## 変更対象` の節が無く、`設計方針` にも SKILL.md の記述が無い) ため、表への `Stopwatch` の行の追加は行っていない。`0115` の変更対象は「行が無いことを確認する (追加されていれば削除する)」であり、行が無い状態でも矛盾しない。

### 公開 API baseline の差分

`make api-baseline` で `TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json` を再生成した。差分は 3 insertions / 1 deletion で、`Utilities.Stopwatch` の class 宣言に対する `deprecated: true` の追加と `declAttributes` への `Available` の追加だけである。`iphoneos26.5.info.txt` は変化しなかった。

```
@@ -43542,8 +43542,10 @@
             "usr": "s:4Sora9UtilitiesO9StopwatchC",
             "mangledName": "$s4Sora9UtilitiesO9StopwatchC",
             "moduleName": "Sora",
+            "deprecated": true,
             "declAttributes": [
-              "Final"
+              "Final",
+              "Available"
             ],
             "conformances": [
               {
```

型の変更、準拠の削除、`printedName` / `declKind` の変化、他の symbol の消滅は無い。`Utilities.randomString(length:)` と `Optional.unwrap(ifNone:)` の宣言は baseline に残っている。

### 実行した検証

検証は Xcode 26.6 / SDK `iphoneos26.5` / Swift 6.3.3 の環境で行った。

- `Sora/` の Swift 6 型検査: error 0 (`grep -cE '^Sora/[^:]+:[0-9]+:[0-9]+: error:'` で 0)、`#SendableClosureCaptures` 0 件。`0108` ゲート相当 (`-warnings-as-errors -Wwarning DeprecatedDeclaration`) でも error 0、warning 17 件 (deprecation は `.treatWarning` で warning に戻る)
- consumer package: `ConsumerCore` / `ConsumerUI` / `ConsumerLegacy` の 3 scheme の Release build が成功し、error 0。`ConsumerLegacy` の log に `.../DeprecatedAPI.swift:56:29: warning: 'Stopwatch' is deprecated: 2027 年中に廃止予定です。` が出る
- `Check Deprecation Warning` の再現: workflow の symbol 一覧を `sed` で取り出し、`'<symbol>' is deprecated` を build log で検査した。一覧の 11 symbol すべてが検出され、`Stopwatch` も含まれる
- `make consumer-check-negative`: 2 件が期待どおり失敗 (`SendableClosureCaptures` / `IsolatedConformances`)
- `make build`: 成功
- `make api-check-fresh`: 成功 (`The committed API baseline matches the current Sora module.`)
- `SoraTests`: 441 件 / skip 31 / 失敗 0 (`Executed 441 tests, with 31 tests skipped and 0 failures (0 unexpected)`)
- `swift format --in-place` (変更した 2 file) は差分を生まなかった。`make fmt-lint` は成功、`swiftlint lint --strict --cache-path build/swiftlint-cache` は violation 0

sandbox では `~/Library/Caches/org.swift.swiftpm` と `~/Library/Developer` への書き込みが拒否されるため、SDK / consumer 系の build は `CFFIXED_USER_HOME="$PWD/build/home" HOME="$PWD/build/home"` を付けて実行した。`xcodebuild test` は PTY の作成が拒否されて test runner を起動できない (`Pseudo Terminal Setup Error ... Operation not permitted`) ため、`build-for-testing` の成果物を使い、`xcrun simctl spawn 643CF0FB-38D6-47D6-A145-EDD331B94DA1 /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/xctest build/Build/Products/Debug-iphonesimulator/SoraTests.xctest` (`SIMCTL_CHILD_DYLD_FRAMEWORK_PATH=build/Build/Products/Debug-iphonesimulator`) で代替した。これは `-destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'` が選ぶ runtime と同じ iOS 26.5 の device であり、`build-for-testing` 自体は成功している。

### 残った懸念

- 本 issue は `0181` が変更した `Sora/Utilities.swift` の `Stopwatch` の内部 (`StopwatchStorage`) を前提にする。着手時点の `develop` は `0181` のマージ (`0545c3c9` を含む `c0b2ddde`) を含んでいたため、`feature/change-deprecate-stopwatch` は `develop` の先端から作成した。`0181` が `develop` に入っていない状態では、本 issue のブランチを `0181` の後に置く必要がある
- `TestConsumers/Swift6Consumer/README.md` の「公開 closure の列挙手順」表にある `Utilities.Stopwatch(handler:)` の記述は本 issue の変更対象ではないため残した。削除は `0115` が行う
- iOS 26.0 の simulator で同じ `SoraTests.xctest` を実行した場合は `DummyVideoCapturerTests.testDeinitWithoutStopReleasesCapturer` で abort した。`isolated deinit` の runtime 差によるものと推測され、指定の iOS 26.5 の runtime では 441 件すべて成功する
- deprecation message の移行先に挙げた `Task.sleep(for:)` は iOS 16 以降の API であり、SDK の対応 OS (iOS 14 以降) では利用できない場合がある。利用者側の実装選択の案内であり、SDK の対応 OS を変えるものではない
