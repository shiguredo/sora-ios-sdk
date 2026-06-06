# iPad で AVAudioSession のカテゴリーが soloAmbient だと音声が再生されない

- Priority: Medium
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/fix-ipad-soloambient-no-audio
- Polished: 2026-06-06

## 目的

特定の iPad 環境において、SDK 接続後にリモート音声が再生されない問題を修正する。

## 優先度根拠

音声が再生されない問題はビデオ通話として致命的な不具合。ただし特定の iPad 端末・iOS バージョン・初期 `AVAudioSession` カテゴリーの組み合わせでのみ再現し、全端末で発生するわけではないため Medium とする。

## 現状

### コードの実態

`initializeSenderStream()` の中で `configuration.audioEnabled` が `true` のとき `initializeAudioInput()` が呼ばれる。`initializeAudioInput()` は以下を順番に行う:

1. `session.setInitialMicrophoneMute(...)` でマイクミュートの初期状態を設定する（`initializeInput` の前にしか変更できないためこの順序が必要）
2. `RTCAudioSessionConfiguration.webRTC().category = AVAudioSession.Category.playAndRecord.rawValue` で WebRTC 設定オブジェクトのカテゴリーを変更する
3. `session.initializeInput` を非同期で呼び出す

`initializeInput` のコールバックでエラーが返った場合、デバッグログ出力のみで `isAudioInputInitialized` は `false` のまま維持される。`isAudioInputInitialized` は `var` で宣言されておりスレッド安全な保護機構がなく、`initializeInput` の非同期コールバック内で書き込まれる。

`initializeSenderStream()` は `createAnswer()` 内で `configuration.isSender == true` かつ初回 offer のときのみ呼ばれるため、`recvonly` ロールでは `initializeSenderStream()` が呼ばれず、`initializeAudioInput()` も呼ばれない。

### 実験結果

特定の iPad 端末で、`sendrecv` ロールで接続し、接続前の `AVAudioSession.category` が `soloAmbient` の状態で以下の変更を加えた場合の動作を確認している（iPhone や `soloAmbient` 以外の初期カテゴリーでは同じコードで音声は正常に再生される）:

| 変更内容 | リモート音声 |
|---|---|
| 変更なし（オリジナルコード） | 再生されない |
| `initializeInput` のみコメントアウト（カテゴリー変更は維持） | 再生される |
| `initializeInput` とカテゴリー変更の両方をコメントアウト | 再生されない |

この結果から:

- `initializeInput` の呼び出しが再生を阻害している（`soloAmbient` 状態の iPad 環境で）
- カテゴリー変更（`RTCAudioSessionConfiguration.webRTC().category = playAndRecord`）は再生に必要と推測される。ただしこの設定変更が `initializeInput` なしで実際に AVAudioSession へ反映されるかは libwebrtc 内部の動作に依存しており未確認
- 阻害メカニズムは未特定（`initializeInput` 自体の問題か、非同期コールバックのタイミング問題かは不明）

### 再現条件

- iPad 端末（機種・iOS バージョン・libwebrtc バージョン未特定）
- 接続開始前の `AVAudioSession.category` が `soloAmbient` の状態
- `sendrecv` ロールで `audioEnabled=true` で接続する

## 設計方針

本 issue は調査フェーズと実装フェーズの 2 段階で進める。

**フェーズ 1（調査）**:

1. 再現端末・iOS バージョン・libwebrtc バージョンを特定し、本 issue の再現条件セクションを更新する
2. `initializeInput` のエラーコールバックが呼ばれているか確認する（デバッグログで `failed to initialize audio input` が出力されるか）
3. `initializeInput` が音声再生を阻害するメカニズムを特定する（タイミング問題か、音声セッション状態の破壊か）

フェーズ 2 移行条件: 項目 1（再現端末・バージョン特定）と項目 2（エラーコールバック確認）が完了し、修正方針を選択できる状態になった時点でフェーズ 2 に着手する。項目 3（阻害メカニズム特定）は方針選択の精度向上に寄与するが必須ではない。

**フェーズ 2（修正）**:

調査結果に応じて以下の候補から方針を選択する:

**方針 A**: `initializeInput` を呼ばない構成オプションを追加する。この方針を採用する場合、`initializeInput` 前にしか設定できない `setInitialMicrophoneMute` が機能しなくなる副作用がある。また `Configuration.initialMicrophoneEnabled` との役割の重複を整理する必要がある

**方針 B**: `initializeInput` の呼び出しタイミングを変更する（例: カテゴリー変更後に適切な同期処理を挟む、または接続確立後に遅延呼び出しする）

**方針 C**: `initializeInput` 失敗時に音声セッション状態をリカバリーする（エラーコールバックが呼ばれる場合に対応）

修正にあたっては `isAudioInputInitialized` の書き込みが現在非同期コールバック内で保護機構なしに行われているため、修正方針によってはスレッド安全性の確保（`@MainActor` への移動または `NSLock` による保護等）を合わせて行うこと。

## 完了条件

- 上記の再現条件でリモート音声が再生されること
- マイクを使用する接続（`sendonly` / `sendrecv`）のマイク機能に影響がないこと
- `recvonly` ロールでの音声受信に影響がないこと（本修正は `recvonly` での `initializeAudioInput()` 呼び出しに影響しないが、デグレがないことを確認する）
- `CHANGES.md` の `develop` セクションに以下を追記すること

```
- [FIX] iPad で AVAudioSession のカテゴリーが soloAmbient だと音声が再生されない問題を修正する
  - @voluntas
```

## 解決方法
