# iPad で AVAudioSession のカテゴリーが soloAmbient だと音声が再生されない

- Priority: Medium
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/fix-ipad-soloambient-no-audio
- Polished:

## 概要

iPad 環境で `AVAudioSession` のカテゴリーが `soloAmbient` の状態のとき、リモート音声が再生されないことがある。

## 現状の確認

SDK では接続時に `RTCAudioSessionConfiguration.webRTC().category` を `AVAudioSession.Category.playAndRecord` に変更し、`RTCAudioSession.sharedInstance().initializeInput` を呼び出している（`Sora/PeerChannel.swift`）。

`initializeInput` をコメントアウトした場合はリモート音声が再生されるが、カテゴリー変更ごとコメントアウトすると再生されなくなることを確認。これはカテゴリー変更による `soloAmbient` への設定が影響している可能性がある。

## 再現性

特定の iPad 環境で再現。全端末で再現するわけではない。

## 根拠

一部の iPad 環境でリモート音声が再生されないのはビデオ通話として致命的な不具合。`AVAudioSession` の設定処理と `initializeInput` の呼び出し順序や条件に問題がある可能性がある。

## 調査方針

- `PeerChannel.swift` の `AVAudioSession` カテゴリー設定処理（`playAndRecord` への変更と `initializeInput` の呼び出し）の前後の状態を調べる
- `soloAmbient` カテゴリーと `playAndRecord` への切り替えが競合する条件を特定する
- iPad と iPhone で挙動が異なる理由を調べる
