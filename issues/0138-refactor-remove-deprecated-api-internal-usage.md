# 非推奨化した API を SDK 内部で使い続けないようにする

- Created: 2026-09-10
- Completed: {YYYY-MM-DD}
- Branch: feature/refactor-remove-deprecated-api-internal-usage
- Polished: {YYYY-MM-DD}

## 目的

SDK が非推奨化した API を SDK 内部で使い続けることで発生する deprecation 警告をなくし、内部の利用経路を非推奨でない API へ揃える。

## 現状

- `PeerChannel.makeSignalingConnect` が `Configuration.spotlightEnabled` (非推奨) を参照している。`Configuration.isSpotlightEnabled` へ置き換えられる。
- `ICEServerInfo` の内部処理が `tlsSecurityPolicy` (非推奨) を参照している。
- `TLSSecurityPolicy` の対応表が内部で非推奨型を参照している。
- ビルド時にこれらの deprecation 警告が出る。

## 設計方針

- `PeerChannel` は `configuration.isSpotlightEnabled` を使って `Configuration.Spotlight` を組み立てる。
- `ICEServerInfo` は非推奨プロパティに依存しない内部表現へ寄せる。公開プロパティの後方互換は維持する。
- 非推奨型の内部参照を減らし、警告を解消する。
- 公開 API の挙動を変えない。

## 完了条件

- SDK 内部で非推奨 API を参照しない。
- ビルドで deprecation 警告が出ない。
- 公開 API の後方互換と挙動を維持する。
- 既存テストがすべて成功する。

## 解決方法
