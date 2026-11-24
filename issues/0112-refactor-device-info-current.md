# DeviceInfo.current の unsafe な共有可変状態を除去する

- Created: 2026-08-27
- Completed: 2026-11-24
- Priority: Medium
- Branch: feature/refactor-device-info-current
- Polished: 2026-11-24
- Refreshed: 2026-11-24

## 目的

`DeviceInfo.current` の public getter / setter の互換性を維持しながら、`nonisolated(unsafe)` な static mutable property を安全な同期 storage へ置き換える。

接続 message の生成と利用者による設定変更が競合しても、一貫した `DeviceInfo` value を取得できるようにする。

## 現状

`Sora/DeviceInfo.swift` の `DeviceInfo` 自体は、immutable な `String` property だけを持つ `Sendable` struct である。

一方、`public static var current` は writable かつ `nonisolated(unsafe)` である。コメントでは、利用者が同時に書き換えないことを安全性の前提としている。

`Sora/PeerChannel.swift` は connect message の environment 生成時に `DeviceInfo.current.description` を読む。利用者が別 executor から `current` を書き換えると、static property の読み書きが競合する。

`currentSystemInfo()` は `UIDevice.current` を MainActor 上で読むため、static initial value の生成経路と static storage の同期は分けて考える必要がある。加えて `currentSystemInfo()` は main thread 以外では `DispatchQueue.main.sync` を行う。現行の `static var current` の初期化子も Swift の static 初期化ロック内でこの関数を呼ぶため、main thread と background thread が同時に初回アクセスすると、現行実装でも deadlock し得る。

`DeviceInfo` の initializer は internal であるため、外部利用者が任意の値を新規作成して setter へ渡す用途は限定的である。ただし public setter の削除は source compatibility に影響するため、本 issue では直ちに read-only へ変更しない。

## 設計方針

- 初期の system snapshot は、storage lock を保持せずに生成し、生成完了後に storage lock 下で未設定の場合のみ publish する。
  - `currentSystemInfo()` が main thread 以外で `DispatchQueue.main.sync` を行うため、`static let` の初期化子 (Swift の static 初期化ロック) の中で生成すると、main thread が同じ static 初期化を待つと deadlock する経路がある。したがって初期 snapshot の生成に `static let` は使わない。
  - 二重生成は許容する。生成結果は同一プロセス内では等しいため、lock 区間で「未設定の場合のみ」publish すれば一貫性は保たれる。
- public `current` は computed property とし、private storage の get / set を 1 つの lock で保護する。
- `DeviceInfo` は immutable value のため、lock 下で value copy を取得した後は lock 外で利用する。
- `UIDevice.current` の読み取りは MainActor 上に限定し、storage lock を保持したまま `DispatchQueue.main.sync` を呼ばない。
- main thread / MainActor からの初期化と background thread からの初回取得が同時に発生しても、SDK 内部の lock に起因する deadlock が起きないことを確認する。main thread を塞いだ状態から background thread が初回取得する呼び出し側の待ちは対象外とする。
- public getter / setter のシグネチャは維持する。
- 将来 setter を削除する場合は、利用実績と source compatibility を確認した別の remove issue で扱う。

## スコープ外

- machine name 取得の sysctl 実装は変更しない。
- `DeviceInfo` の公開 initializer 追加は行わない。
- environment signaling field の形式は変更しない。
- `Sora` の他の共有 state は `0111` (2026-11-20 完了) で対応済みであり、本 issue では扱わない。

## 変更対象

- `Sora/DeviceInfo.swift`: `nonisolated(unsafe)` の除去、lock 付き private storage と computed property への置き換え、初期 snapshot 生成を lock 外へ移す
- `SoraTests/DeviceInfoTests.swift` (新規): 並行読み書き、同時初回取得、snapshot 一貫性のテスト
- `TestConsumers/Swift6Consumer/ApiBaseline/` (`iphoneos26.5.json` / `iphoneos26.5.info.txt`): `DeviceInfo.current` を stored property から computed property へ変えると ABI dump の `declAttributes` (`HasInitialValue` / `Nonisolated` / `HasStorage`) と `hasStorage`、accessor の `implicit` / `Transparent` が変わるため、同じ変更で `make api-baseline` (Xcode 26.6 / `iphoneos26.5`) により再生成する (`CODEBASE.md` の「baseline を更新する手順」)
- `skills/sora-ios-sdk/SKILL.md`: 「スレッド安全でない共有状態」の一覧から `DeviceInfo.current` を除去する (`0106` は develop にマージ済み)。`0106` の完了により一覧の項目が `DeviceInfo.current` だけになったため、同節の見出しと導入文を削除し、同節に残るカメラ操作の説明 (カメラ操作の直列化、`CameraVideoCapturer` の状態保護、`CameraVideoCapturer.stream` の保持の注意) は `### カメラ操作` 節の末尾へ段落ごと移す
- `CHANGES.md`: `## develop` の主リストの `[UPDATE]` の並びへ `[UPDATE]` を追記する

## テスト方針

モックやスタブは使用しない。

- 実 `DeviceInfo.current` を main thread と複数の background queue から同時に読み書きする。
- 実 `DeviceInfo.current` を書き換えるテストは、`setUp` で元の `DeviceInfo` を保存し、`tearDown` で復元して復元を検証する (`LoggerTests` の `Logger.shared` の復元と同じ)。
- `PeerChannel` の connect message 生成と `DeviceInfo.current` の変更を競合させ、取得した description が有効な 1 snapshot に一致することを確認する。
- 初期 snapshot の生成が storage lock を保持せずに行われることを、未初期化の storage をテストで新規生成して確認する。main thread と background thread の同時初回アクセスは test runner をハングさせ得るため直接テストせず、lock 外生成・実 main.sync・生成中 setter の分解テストとコードレビューで、SDK 内部の lock に起因する deadlock が起きないことを確認する (storage はテストから生成できる内部構造にする。モックやスタブは使わない)。
- main thread からの初回取得と background thread からの初回取得を、未初期化の storage を別々に生成して 1 プロセス内で確認する (プロセスをまたぐ別 test run は不要)。
- Thread Sanitizer を補助的に有効化して static storage の競合がないことを確認する (`0119` は 2026-09-30 に完了し、`.github/workflows/e2e-test.yml` の `tsan` job が `SoraTests` 全体を TSan 有効で実行する。完了条件には含めない)。
- system name、system version、machine name の既存形式が維持されることを確認する。
- テストには、MainActor と storage lock の取得順を日本語コメントで明記する。

## 完了条件

- `DeviceInfo.current` から `nonisolated(unsafe)` が除去されていること。
- static storage の get / set が同じ lock で保護されていること。
- 初期 snapshot の生成が storage lock を保持したまま行われず、Swift の static 初期化 (`static let` / `static var` の初期化子) の中で行われていないこと。
- storage lock を保持したまま MainActor または main queue を同期 wait しないこと。
- main thread と background thread のどちらが先に初回取得しても、また両者が同時に初回取得しても、SDK 内部の lock に起因する deadlock が起きないこと (main thread を塞いだ状態で background thread が初回取得する場合の待ちは呼び出し側の責務とする)。
- connect message が一貫した `DeviceInfo` snapshot を使用すること。
- public getter / setter の source compatibility が維持されること。
- `make api-check-fresh` が成功し、`TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json` の差分が `DeviceInfo.current` の ABI 表現の変化だけであり、他の公開宣言の追加・変更・削除が無いこと。
- environment の文字列表現が変わらないこと。
- `skills/sora-ios-sdk/SKILL.md` の「スレッド安全でない共有状態」の一覧から `DeviceInfo.current` が除去され、同節の見出しと導入文が削除され、同節に残るカメラ操作の説明 (カメラ操作の直列化、`CameraVideoCapturer` の状態保護、`CameraVideoCapturer.stream` の保持の注意) が `### カメラ操作` 節の末尾へ段落ごと移されていること。
- `CHANGES.md` の `## develop` へ `[UPDATE]` が追記されていること。
- 追加したテストと既存テストがすべて成功すること。
- 実 `DeviceInfo.current` を書き換えるテストが元の値へ復元し、後続テストへ影響を残さないこと。

## 解決方法

`DeviceInfo.current` を `nonisolated(unsafe)` な static stored property から、`NSLock` で保護した内部 `DeviceInfoStorage` の computed property へ変更した。初期 snapshot は storage lock の外で生成し、生成後に未設定の場合だけ publish する。setter が先に設定した場合や、生成中に別の値が publish された場合は、その値を返す。getter / setter のシグネチャと `DeviceInfo` の公開 property は変えていない。

- `DeviceInfo.makeSnapshot()` を internal factory として追加し、初期 snapshot の生成経路をテストからも利用できるようにした。
- `SoraTests/DeviceInfoTests.swift` を追加し、並行読み書き、connect message の snapshot 一貫性、実 `currentSystemInfo()` の main / background、lock 外生成、setter 優先、publish 後の再生成抑止を検証した。
- `DeviceInfo.current` の API Doc に、main thread を塞いだ状態で background thread が初回取得する場合の注意と、main thread での warm-up を追記した。
- `SKILL.md` の「スレッド安全でない共有状態」から `DeviceInfo.current` を除去し、`CHANGES.md` に `[UPDATE]` を追加した。

検証は build-for-testing 成功、`DeviceInfoTests` 13 件 0 失敗、全 `SoraTests` 624 件 (40 skipped) 0 失敗、TSan 0 警告、swift-format / SwiftLint 0 違反である。

API baseline (`TestConsumers/Swift6Consumer/ApiBaseline/iphoneos26.5.json`) は Xcode 26.6 / `iphoneos26.5` で更新済みである。`DeviceInfo.current` の ABI 表現だけが更新され、他の公開宣言に差分が無いことを確認した。
