# iPad で AVAudioSession のカテゴリーが soloAmbient だと音声が再生されない

- Priority: Medium
- Created: 2026-06-06
- Completed:
- Model: Sonnet 4.6
- Branch: feature/fix-ipad-soloambient-no-audio
- Polished: 2026-10-29
- Updated: 2026-10-29

## 目的

特定の iPad 環境において、SDK 接続後にリモート音声が再生されない問題を修正する。

## 優先度根拠

音声が再生されない問題はビデオ通話として致命的な不具合。ただし特定の iPad 端末・iOS バージョン・初期 `AVAudioSession` カテゴリーの組み合わせでのみ再現し、全端末で発生するわけではないため Medium とする。

## 現状

### コードの実態

`initializeSenderStream()` の中で `snapshot.audioEnabled` が `true` かつ `snapshot.usesCustomAudioDevice` が `false` のとき `initializeAudioInput()` が呼ばれる。カスタム音声デバイス（`DummyAudioDevice` 等）が設定されている場合は `initializeAudioInput()` は呼ばれず、`AVAudioSession` の設定はデバイス側の `RTCAudioDevice` 実装が行う。カスタム音声デバイスを使う接続は `AudioSessionUsage.custom` として音声セッションの競合判定に参加し、ステレオ音声出力とは同時に利用できない。`Configuration.audioDevice` は `:nodoc:` の internal プロパティであり、SDK ではテストから `DummyAudioDevice` を注入するために使用している。

`initializeAudioInput()` は以下を順番に行う:

1. `session.setInitialMicrophoneMute(...)` でマイクミュートの初期状態を設定する（`initializeInput` の前にしか変更できないためこの順序が必要）
2. `session.initializeInput` を非同期で呼び出す

音声セッションのカテゴリー（`playAndRecord`）は `initializeAudioInput()` では設定しない。ステレオ音声出力を使わない送信側の接続では `AudioSessionCoordinator.requirePlayAndRecord(id:)` が `RTCAudioSessionConfiguration` の WebRTC テンプレートを複製して差し替え、`NativePeerChannelFactory` の init が ADM の生成前にこの要求を確定する。ステレオ音声出力を使う送信側では ADM の生成後に同じ要求を行う。受信専用の接続は `playAndRecord` を要求せず、この差し替えも行わない。この経路は 2026.3.0 のステレオ音声出力対応（コミット `003bb738`）で入ったもので、それ以前は `initializeAudioInput()` の中で `RTCAudioSessionConfiguration.webRTC().category` を直接書き換えていた。

`initializeInput` のコールバックでエラーが返った場合、デバッグログ出力のみで初期化済みフラグは立たない。このフラグは `ConnectionStateOwner` が単一所有し、`initializeInput` の非同期コールバックから `.audioInputInitialized` イベントを経由して直列 queue 上で書き込まれる（2026.4.0、コミット `491bae3a` で `PeerChannel` の保護なし `var` から移行済み）。「未初期化なら初期化する」判定と書き込みの原子性は無い。

`initializeSenderStream()` は `createAnswer()` 内で `snapshot.isSender == true` かつ初回 offer のときのみ呼ばれるため、`recvonly` ロールでは `initializeSenderStream()` が呼ばれず、`initializeAudioInput()` も呼ばれない。送信側の接続だけがマイク入力を初期化する契約は、closed 済みの issue 0133 で実機検証されている。

### 実験結果

以下は 2026.3.0（コミット `003bb738`）より前の実装で行った観測である（観測日と観測時の SDK / libwebrtc ビルドは記録していない）。当時はカテゴリー変更が `initializeAudioInput()` の中にあったため、「`initializeInput` だけをコメントアウトしてカテゴリー変更は維持する」操作が同じ関数内で成立していた。現行コードではカテゴリー変更が `AudioSessionCoordinator` へ分離され、ステレオ音声出力を使わない接続では ADM の生成前に確定するため、この操作の意味は変わり、「カテゴリー変更もコメントアウトする」操作は `initializeAudioInput()` の中では実現できない。現行コードで同じ条件を作る方法には、例えば `NativePeerChannelFactory` が呼ぶ `requirePlayAndRecord()` を外す、`AudioSessionCoordinator.requirePlayAndRecord(id:)` の `RTCAudioSessionConfiguration.setWebRTC(_:)` を外す、`MediaChannel` の init で `requiresPlayAndRecord` を `false` にする、などがある。`requirePlayAndRecord()` を外す方法では `pendingPlayAndRecordRequirementIDs` に ID が残り、接続中は別の音声接続が `SoraError.connectionBusy` になる。

特定の iPad 端末で、`sendrecv` ロールで接続し、接続前の `AVAudioSession.category` が `soloAmbient` の状態で以下の変更を加えた場合の動作を確認している（iPhone や `soloAmbient` 以外の初期カテゴリーでは同じコードで音声は正常に再生される）:

| 変更内容 | リモート音声 |
|---|---|
| 変更なし（オリジナルコード） | 再生されない |
| `initializeInput` のみコメントアウト（カテゴリー変更は維持） | 再生される |
| `initializeInput` とカテゴリー変更の両方をコメントアウト | 再生されない |

この結果から:

- `initializeInput` の呼び出しが再生を阻害している（`soloAmbient` 状態の iPad 環境で）
- カテゴリー変更（`RTCAudioSessionConfiguration.webRTC().category = playAndRecord`）は再生に必要と推測される。ただしこの設定変更が実際に `AVAudioSession` へ反映される時点は libwebrtc 内部の動作に依存しており、現行のステレオ音声出力を使わない接続の「ADM 生成前にテンプレートを差し替える」経路でも未確認である
- 阻害メカニズムは未特定（`initializeInput` 自体の問題か、非同期コールバックのタイミング問題かは不明）

### 再現条件

- iPad 端末（機種・iOS バージョン未特定）
- 接続開始前の `AVAudioSession.category` が `soloAmbient` の状態
- `sendrecv` ロールで `audioEnabled=true` で接続する

再観測はその時点の `Package.swift` が指定するビルドで行い、バージョンと観測日を記録する。

## 設計方針

本 issue は調査フェーズと実装フェーズの 2 段階で進める。

**フェーズ 1（調査）**:

1. 再現端末と iOS バージョンを特定し、本 issue の再現条件セクションを更新する。再観測に使った SDK / libwebrtc のビルドと観測日も記録する
2. `initializeInput` のエラーコールバックが呼ばれているか確認する（`Sora.logLevel = .debug` を設定し、デバッグログに `failed to initialize audio input => <error>` が出力されるか確認する。既定のログレベル `info` では出力されない）
3. `initializeInput` が音声再生を阻害するメカニズムを特定する（タイミング問題か、音声セッション状態の破壊か）
4. `initializeInput` を呼ばない状態で、相手への音声送信（マイク入力）と受信の両方が機能するか実機の `sendrecv` 送受信で確認する（実験結果は受信再生のみ観測しており、送信側は未検証のため）
5. 現行の develop で実験結果の表を再観測する（カテゴリー要求の有無 × `initializeInput` の呼び出し有無）。カテゴリー要求は `AudioSessionCoordinator` が管理しているため、要求の有無は `MediaChannel` の init に渡す `requiresPlayAndRecord` などで切り替える

フェーズ 2 移行条件: 項目 1（再現端末・バージョン特定）、項目 2（エラーコールバック確認）、項目 5（現行コードでの再観測）が完了し、現行コードでも症状が再現したうえで修正方針を選択できる状態になった時点でフェーズ 2 に着手する。項目 3（阻害メカニズム特定）は方針選択の精度向上に寄与するが必須ではない。項目 4（`initializeInput` なしの送受信検証）は、後述の方針 A を選択する場合の必須条件とする。現行コードで症状が再現しない場合は、フェーズ 2 に進まず原因の変化を調査して本 issue の要否を判断する。

**フェーズ 2（修正）**:

調査結果に応じて以下の候補から方針を選択する。選択基準は次のとおり。

- **方針 A を選択する条件**: 項目 2 の結果に関わらず、再現端末で「`initializeInput` を呼ばないとリモート音声が再生される」ことが同一手順の複数回の接続で安定して確認でき、かつ項目 4 で `initializeInput` なしでも送受信の両方が機能することが確認できた場合。
- **方針 B を選択する条件**: 項目 3 の調査で阻害メカニズムがタイミング問題と特定され、呼び出しタイミングの変更だけで再生とマイク送信の両方が成立すると判断できる場合。
- **方針 C を選択する条件**: 項目 2 で `initializeInput` のエラーコールバック（`failed to initialize audio input`）が確認され、かつエラー後のリカバリーで再生とマイク送信の両方が成立すると判断できる場合。

複数の方針の条件が同時に成立した場合は、公開 API の追加を伴わない方針を優先し、その中で変更範囲が小さいものを選ぶ。いずれの条件も成立しない場合はフェーズ 1 を継続し、方針を決めない。

**方針 A**: `initializeInput` を呼ばない構成オプションを追加する。カスタム音声デバイスを `Configuration.audioDevice` に設定した場合は既に `initializeAudioInput()` を呼ばずに音声送信が E2E で確認されており、これを参考に設計する（ただしカスタム `RTCAudioDevice` 経路であり、デフォルトの ADM 経路で `initializeInput` を呼ばない場合の影響は項目 4 で確認する）。オプションを公開 API として追加するか internal な自動判定にするか、既定値をどちらにするか、利用者が明示的に有効化するのか SDK が自動で切り替えるのかは、フェーズ 1 の結果を踏まえてフェーズ 2 で確定する。この方針を採用する場合、`initializeInput` 前にしか設定できない `setInitialMicrophoneMute` が機能しなくなる可能性があり、`Configuration.initialMicrophoneEnabled` による初期ミュートを代替手段で維持するか、契約の変更として告知して移行方法を示すかを決める必要がある（`MediaChannel.setAudioHardMute(_:)` は `state == .connected` を要求するため、接続時点の初期ミュートを同じ契約で維持できるかは未確定である）。公開 API を追加する場合は、`CHANGES.md` の `[ADD]` と公開 API baseline の再生成も必要になる

**方針 B**: `initializeInput` の呼び出しタイミングを変更する。ただし `RTCAudioSession.initializeInput` は「入力を使用する場合だけ AudioUnit の生成前に 1 回呼ぶ」契約であり、`setInitialMicrophoneMute` は入力初期化後に `NO` を返す。現行 SDK には ADM / AudioUnit の初期化完了を通知する API が無いため、AudioUnit の生成前に収まる範囲で、どのタイミングへ変更できるかをフェーズ 1 で確認してから具体案を決める

**方針 C**: `initializeInput` 失敗時に音声セッション状態をリカバリーする（エラーコールバックが呼ばれる場合に対応）。初期化失敗を接続へ通知する経路は、ネイティブ音声の初期化失敗を対象の接続へ通知する issue 0130（open）と隣接するため、通知を共通化する場合は両者の責務を整理すること

`isAudioInputInitialized` は 2026.4.0（コミット `491bae3a`）で `ConnectionStateOwner` の単一所有 + 直列 queue + `.audioInputInitialized` イベントへ移行済みである。ただし「未初期化なら初期化する」判定と書き込みの原子性は無いため、修正する場合はこの所有者とイベント経路を維持すること。

## 完了条件

- 上記の再現条件の接続でリモート音声が再生されること。方針 A でオプションを追加する場合は、そのオプションを有効にした接続で確認する
- マイクを使用する接続（`sendonly` / `sendrecv`）のマイク機能に影響がないこと。方針 A を採用する場合は、`Configuration.initialMicrophoneEnabled` による初期ミュートの契約をどう扱うかを決めて `CHANGES.md` に反映すること。代替手段で契約を維持する場合は実現方法（`MediaChannel.setAudioHardMute(_:)` は `state == .connected` を要求するため、接続時点の扱いを含む）を明記し、契約を変える場合は `[CHANGE]` として告知して移行方法を示すこと
- `recvonly` ロールでの音声受信に影響がないこと（`recvonly` は `initializeAudioInput()` を呼ばないため本修正の対象外だが、デグレがないことを確認する）
- `CHANGES.md` の `develop` セクションに以下を追記すること。方針 A で公開 API（`Configuration` のプロパティ等）を追加する場合は `[ADD]` も追記し、同じ変更で `make api-baseline` により `TestConsumers/Swift6Consumer/ApiBaseline/` を再生成して `make api-check-fresh` が成功すること

```
- [FIX] iPad で AVAudioSession のカテゴリーが soloAmbient だと音声が再生されない問題を修正する
  - @voluntas
```

## 解決方法
