# Objective-C からの利用に対応する

- Priority: Low
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/add-objc-support
- Polished: 2026-09-24

## 概要

Sora iOS SDK を Objective-C のコードから直接利用できるようにする。Objective-C で書かれた既存コードベースや、Objective-C ベースのブリッジ（React Native のネイティブモジュールなど）から SDK を扱えるようにすることが主な動機。

## 背景

- SDK は Swift で書かれており、公開 API の大半が Swift 固有の表現に依存している
  - `Configuration` は構造体である（`Sora/Configuration.swift`）
  - `MediaChannel`、`Sora`、`ConnectionTask`、各ハンドラークラス（`SoraHandlers`、`MediaChannelHandlers` 等）は `NSObject` を継承していない
  - `SoraCloseEvent` のような associated values を持つ enum、protocol、ジェネリクス型が公開されている
  - `MediaChannel` には async メソッド（`setVideoHardMute(_:)`、`startScreenCapture(settings:)`、`stopScreenCapture()` 等）がある
- Objective-C から Swift の API を利用するには、公開 API が Objective-C で表現可能であることと、生成される `-Swift.h` ヘッダー（または同等の取り込み経路）を利用できることが必要になる
- React Native の iOS ネイティブモジュールは Objective-C++ で書くのが標準だが、Swift と Objective-C++ の接着層を使った実装も公式に提供されている。Swift で実装する場合は RN モジュール側から Sora（SwiftPM パッケージ）を直接 import できる。一方、Objective-C で書かれたモジュールからは、Sora が ObjC 対応していなければ利用できない
- SDK は現在 SwiftPM のみで配布されている（CocoaPods での提供は廃止済み）

## 対応方針

### 案 A：公開 API に `@objc` を付与する

`@objc` を付与できるのは Objective-C で表現可能な宣言に限られる。クラスに付与する場合、そのクラスは `NSObject` を継承している必要がある。現状の公開 API では:

- `@objc` を付与できるのは、`NSObject` を継承させた `MediaChannel`、`Sora`、`ConnectionTask`、各ハンドラークラス等に限られる
- `Configuration` は構造体のため `@objc` を付与できない
- associated values を持つ enum（`SoraCloseEvent`）、protocol、ジェネリクス型にも `@objc` を付与できない
- async メソッドは ObjC からは completion handler 形式で扱うことになる

`@objcMembers` によるクラス単位の一括対応は可能だが、適用できるのは `NSObject` を継承したクラスに限られる。`NSObject` 継承の追加は公開 API の構造変更になるため、既存の Swift 利用者へのソース互換性を確認しながら進める。

### 案 B：ObjC ラッパーを別途用意する

- Swift API に対する ObjC 用のラッパークラスを別ファイルで提供する
- 公開 API の設計を変えずに済むが、ラッパーのメンテコストが発生する

### 優先する案

案 A を優先し、`@objc` を付与できない型（`Configuration`、associated values 付き enum、protocol、ジェネリクス型等）についてのみ案 B のブリッジを用意する。案 A だけで対応できる範囲は限定的であり、公開 API の大半はブリッジ対象になることを前提とした工数見積りで進める。

## 確認事項

- Objective-C のコードから Sora モジュールを取り込む経路を確認する。SwiftPM のライブラリターゲットは `-Swift.h` ヘッダー（`Sora-Swift.h`）の生成が保証されないため、framework 化して配布する必要があるかを Xcode のバージョンを含めて確認する
- ObjC 対応の対象範囲（主要 API のみか全公開 API か）を確定する
- 既存の公開 Swift API とのソース互換性を保てることを確認する
- ObjC 対応に伴うバイナリサイズへの影響を確認する
- `@objc` を付与することで Swift の最適化（メソッドのインライン化等）に影響がないか確認する

## 完了条件

- Objective-C のコードから Sora を import し、主要な利用フロー（接続・切断、映像の表示・送信、メッセージング、カメラ操作）を実行できる
- 対象範囲は上記の主要フローに必要な公開 API とし、`RPC`、統計取得などの高度な機能は対象外であることを明記する
- 既存の利用者が使う公開 Swift API に互換性のない変更を加えていない

## 根拠

時雨堂やサードパーティ製の iOS アプリには Objective-C で書かれたコードベースが残っており、それらを Swift へ全面移行せずに Sora を利用できるようにする。React Native のネイティブモジュールを Objective-C(++) で実装する場合にも、Sora の ObjC 対応が必要になる。
