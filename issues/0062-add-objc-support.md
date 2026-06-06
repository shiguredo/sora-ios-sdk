# Objective-C からの利用に対応する

- Priority: Low
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/add-objc-support
- Polished:

## 概要

Sora iOS SDK を Objective-C から利用できるようにする。React Native（Objective-C ブリッジ）などから SDK を扱えるようにすることが主な動機。

## 背景

Swift で書かれた SDK は `@objc` 属性を付与することで Objective-C から利用可能になる。React Native の Native Module は Objective-C（または Swift with ObjC-compatible interface）を必要とするため、SDK が ObjC 対応していないと React Native 経由での利用が困難。

## 対応方針

### 案 A：公開 API に `@objc` を付与する

- Swift の公開 API（`MediaChannel`、`Configuration`、各ハンドラー等）に `@objc` を付与する
- `@objcMembers` を使ってクラス単位で一括対応することも検討する
- Swift 固有の機能（`enum` with associated values、`struct` 等）は ObjC から扱えないため、ObjC 向けに別クラスを用意するか設計を調整する
- `NSObject` を継承していないクラスへの対応を確認する

### 案 B：ObjC ラッパーを別途用意する

- Swift API に対する ObjC ラッパークラスを別ファイルで提供する
- 公開 API の設計を変えずに済むが、ラッパーのメンテコストが発生する

## 優先する案

案 A が実装コスト・メンテコストともに低い。`@objc` を付与できない箇所についてのみ個別に対応する。

## 確認事項

- ObjC 対応に伴うバイナリサイズへの影響を確認する
- `@objc` を付与することで Swift の最適化（メソッドのインライン化等）に影響がないか確認する

## 根拠

React Native をはじめとした ObjC ブリッジが必要なフレームワーク経由での利用要望がある。ObjC 対応することで SDK の利用範囲が広がる。
