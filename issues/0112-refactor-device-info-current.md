# DeviceInfo.current の unsafe な共有可変状態を除去する

- Created: 2026-08-27
- Completed:
- Branch: feature/refactor-device-info-current
- Polished: 2026-09-17

## 目的

`DeviceInfo.current` の public getter / setter の互換性を維持しながら、`nonisolated(unsafe)` な static mutable property を安全な同期 storage へ置き換える。

接続 message の生成と利用者による設定変更が競合しても、一貫した `DeviceInfo` value を取得できるようにする。

## 現状

`Sora/DeviceInfo.swift` の `DeviceInfo` 自体は、immutable な `String` property だけを持つ `Sendable` struct である。

一方、`public static var current` は writable かつ `nonisolated(unsafe)` である。コメントでは、利用者が同時に書き換えないことを安全性の前提としている。

`Sora/PeerChannel.swift` は connect message の environment 生成時に `DeviceInfo.current.description` を読む。利用者が別 executor から `current` を書き換えると、static property の読み書きが競合する。

`currentSystemInfo()` は `UIDevice.current` を MainActor 上で読むため、static initial value の生成経路と static storage の同期は分けて考える必要がある。加えて `currentSystemInfo()` は off-main では `DispatchQueue.main.sync` を行う。現行の `static var current` の初期化子も Swift の static 初期化ロック内でこの関数を呼ぶため、main thread と background thread が同時に初回アクセスすると、現行実装でも deadlock し得る。

`DeviceInfo` の initializer は internal であるため、外部利用者が任意の値を新規作成して setter へ渡す用途は限定的である。ただし public setter の削除は source compatibility に影響するため、本 issue では直ちに read-only へ変更しない。

## 設計方針

- 初期の system snapshot は、storage lock を保持せずに生成し、生成完了後に storage lock 下で未設定の場合のみ publish する。
  - `currentSystemInfo()` が off-main で `DispatchQueue.main.sync` を行うため、`static let` の初期化子 (Swift の static 初期化ロック) の中で生成すると、main thread が同じ static 初期化を待つ同時初回取得で deadlock する。したがって初期 snapshot の生成に `static let` は使わない。
  - 二重生成は許容する。生成結果は同一プロセス内では等しいため、lock 区間で「未設定の場合のみ」publish すれば一貫性は保たれる。
- public `current` は computed property とし、private storage の get / set を 1 つの lock で保護する。
- `DeviceInfo` は immutable value のため、lock 下で value copy を取得した後は lock 外で利用する。
- `UIDevice.current` の読み取りは MainActor 上に限定し、storage lock を保持したまま `DispatchQueue.main.sync` を呼ばない。
- main thread / MainActor からの初期化と background thread からの初回取得が同時に発生しても deadlock しないことを確認する。
- public getter / setter のシグネチャは維持する。
- 将来 setter を削除する場合は、利用実績と source compatibility を確認した別の remove issue で扱う。

## スコープ外

- machine name 取得の sysctl 実装は変更しない。
- `DeviceInfo` の公開 initializer 追加は行わない。
- environment signaling field の形式は変更しない。
- `Sora` の他の共有 state は `0111` で扱う。

## 変更対象

- `Sora/DeviceInfo.swift`: `nonisolated(unsafe)` の除去、lock 付き private storage と computed property への置き換え、初期 snapshot 生成を lock 外へ移す
- `SoraTests/DeviceInfoTests.swift` (新規): 並行読み書き、同時初回取得、snapshot 一貫性のテスト
- `skills/sora-ios-sdk/SKILL.md`: 「スレッド安全でない共有状態」の一覧から `DeviceInfo.current` を除去する
- `CHANGES.md`: `## develop` へ `[UPDATE]` を追記する

## テスト方針

モックやスタブは使用しない。

- 実 `DeviceInfo.current` を main thread と複数の background queue から同時に読み書きする。
- `PeerChannel` の connect message 生成と `DeviceInfo.current` の変更を競合させ、取得した description が有効な 1 snapshot に一致することを確認する。
- 初期 snapshot の生成が storage lock を保持せずに行われることを、未初期化の storage をテストで新規生成して確認する。main thread と background thread の同時初回アクセスを含め、deadlock しないことを検証する (storage はテストから生成できる内部構造にする。モックやスタブは使わない)。
- main thread からの初回取得と background thread からの初回取得を、プロセスをまたぐ必要がある場合に備えて別 test run でも確認する。
- Thread Sanitizer を補助的に有効化して static storage の競合がないことを確認する (`0119` の基盤が利用可能になった時点で実行し、完了条件には含めない)。
- system name、system version、machine name の既存形式が維持されることを確認する。
- テストには、MainActor と storage lock の取得順を日本語コメントで明記する。

## 完了条件

- `DeviceInfo.current` から `nonisolated(unsafe)` が除去されていること。
- static storage の get / set が同じ lock で保護されていること。
- 初期 snapshot の生成が storage lock を保持したまま行われず、Swift の static 初期化 (`static let` / `static var` の初期化子) の中で行われていないこと。
- storage lock を保持したまま MainActor または main queue を同期 wait しないこと。
- main thread と background thread のどちらが先に初回取得しても、また両者が同時に初回取得しても deadlock しないこと。
- connect message が一貫した `DeviceInfo` snapshot を使用すること。
- public getter / setter の source compatibility が維持されること。
- environment の文字列表現が変わらないこと。
- `skills/sora-ios-sdk/SKILL.md` の「スレッド安全でない共有状態」の一覧から `DeviceInfo.current` が除去されていること。
- `CHANGES.md` の `## develop` へ `[UPDATE]` が追記されていること。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
