# App Extension に対応する

- Priority: Low
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/add-app-extension-support
- Polished:

## 概要

App Extension 開発で Sora iOS SDK を導入した際に、Xcode のビルドオプション "Require Only App-Extension-Safe API" を有効にしてビルドできるようにする。

## 背景

現在、App Extension 環境で SDK を使う場合は "Require Only App-Extension-Safe API" オプションを無効にする必要があり、App Extension の制約に違反する API を使っている箇所がある。Broadcast Upload Extension などを使った画面共有（`0053` 参照）の実現においても App Extension 対応は必要になる。

## 対応方針

- `APPLICATION_EXTENSION_API_ONLY = YES` の設定でビルドが通るようにコードを修正する
- App Extension で使用できない API（`UIApplication.shared` 等）の使用箇所を特定して置き換えるか条件付きコンパイルで除外する
- `AudioSession` 操作など App Extension での制約が特に厳しい箇所を重点的に確認する

## 確認方法

1. SDK のターゲットに `APPLICATION_EXTENSION_API_ONLY = YES` を設定する
2. ビルドエラーとなる箇所をすべて列挙する
3. 各エラー箇所について App Extension 対応の代替実装を検討・適用する

## 根拠

App Extension（特に Broadcast Upload Extension）を利用した画面共有は iOS 映像配信の重要なユースケース。SDK が App Extension 環境で動作しないことは利用者の実装の幅を狭める。
