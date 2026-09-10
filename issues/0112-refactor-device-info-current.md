# DeviceInfo.current の unsafe な共有可変状態を除去する

- Created: 2026-08-27
- Completed:
- Branch: feature/refactor-device-info-current
- Polished:

## 目的

`DeviceInfo.current` の public getter / setter の互換性を維持しながら、`nonisolated(unsafe)` な static mutable property を安全な同期 storage へ置き換える。

接続 message の生成と利用者による設定変更が競合しても、一貫した `DeviceInfo` value を取得できるようにする。

## 現状

`Sora/DeviceInfo.swift` の `DeviceInfo` 自体は、immutable な `String` property だけを持つ `Sendable` struct である。

一方、`public static var current` は writable かつ `nonisolated(unsafe)` である。コメントでは、利用者が同時に書き換えないことを安全性の前提としている。

`Sora/PeerChannel.swift` は connect message の environment 生成時に `DeviceInfo.current.description` を読む。利用者が別 executor から `current` を書き換えると、static property の読み書きが競合する。

`currentSystemInfo()` は `UIDevice.current` を MainActor 上で読むため、static initial value の生成経路と static storage の同期は分けて考える必要がある。

`DeviceInfo` の initializer は internal であるため、外部利用者が任意の値を新規作成して setter へ渡す用途は限定的である。ただし public setter の削除は source compatibility に影響するため、本 issue では直ちに read-only へ変更しない。

## 設計方針

- 初期の system snapshot を `static let` または thread-safe な lazy initialization で 1 回だけ生成する。
- public `current` は computed property とし、private storage の get / set を 1 つの lock で保護する。
- `DeviceInfo` は immutable value のため、lock 下で value copy を取得した後は lock 外で利用する。
- `UIDevice.current` の読み取りは MainActor 上に限定し、storage lock を保持したまま `DispatchQueue.main.sync` を呼ばない。
- main thread / MainActor からの初期化と background thread からの初回取得の両方で deadlock しないことを確認する。
- public getter / setter のシグネチャは維持する。
- 将来 setter を削除する場合は、利用実績と source compatibility を確認した別の remove issue で扱う。

## スコープ外

- machine name 取得の sysctl 実装は変更しない。
- `DeviceInfo` の公開 initializer 追加は行わない。
- environment signaling field の形式は変更しない。
- `Sora` の他の共有 state は `0111` で扱う。

## テスト方針

モックやスタブは使用しない。

- 実 `DeviceInfo.current` を main thread と複数の background queue から同時に読み書きする。
- `PeerChannel` の connect message 生成と `DeviceInfo.current` の変更を競合させ、取得した description が有効な 1 snapshot に一致することを確認する。
- main thread からの初回取得と background thread からの初回取得を別 process / test run で確認する。
- Thread Sanitizer を有効にして static storage の競合がないことを確認する。
- system name、system version、machine name の既存形式が維持されることを確認する。
- テストには、MainActor と storage lock の取得順を日本語コメントで明記する。

## 完了条件

- `DeviceInfo.current` から `nonisolated(unsafe)` が除去されていること。
- static storage の get / set が同じ lock で保護されていること。
- storage lock を保持したまま MainActor または main queue を同期 wait しないこと。
- main thread と background thread のどちらから初回取得しても deadlock しないこと。
- connect message が一貫した `DeviceInfo` snapshot を使用すること。
- public getter / setter の source compatibility が維持されること。
- environment の文字列表現が変わらないこと。
- 追加したテストと既存テストがすべて成功すること。

## 解決方法
