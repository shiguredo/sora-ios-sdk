# iOS SDK の NOTICE ファイルの要否を確認する

- Priority: Low
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/investigate-notice-file
- Polished:

## 概要

Sora iOS SDK に NOTICE ファイルが必要かどうかを調査し、必要であれば作成する。

## 背景

Sora C++ SDK およびそれを利用する SDK には NOTICE ファイルが用意されており、利用ライブラリのライセンスが記載されている。iOS SDK には現時点で NOTICE ファイルが存在しておらず、他の SDK との統一が必要かどうかを判断する必要がある。

## 調査内容

- iOS SDK が依存するライブラリ（libwebrtc 等）のライセンス表示義務を確認する
- libwebrtc が内包するサードパーティライブラリ（libyuv 等）のライセンスが SDK 配布時に表示義務を持つかを確認する
- C++ SDK の NOTICE ファイルの記載内容を参照し、iOS SDK に必要な記載を洗い出す
- Swift Package として配布する場合のライセンス表示方法を確認する

## 対応

調査の結果 NOTICE ファイルが必要と判断した場合は、リポジトリのルートに `NOTICE` ファイルを作成して利用ライブラリとそのライセンスを記載する。

## 根拠

ライセンス義務の不履行はリポジトリ利用者・配布先のアプリに法的リスクをもたらす可能性がある。C++ SDK 等との統一も踏まえ、要否を明確にしておく必要がある。
