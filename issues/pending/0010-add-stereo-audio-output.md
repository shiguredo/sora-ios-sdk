# ステレオ音声出力に対応する

- Priority: Low
- Created: 2026-06-03
- Completed:
- Model: Opus 4.8
- Branch: feature/add-stereo-audio-output
- Polished: 2026-06-05

## Pending 理由

本 issue は以下の理由により pending とする:

1. **外部依存が未確認**: WebRTC-Build 側で ADM のステレオ playout および Opus デコーダのステレオ再生が有効になっているかが未確認。特に iOS の libwebrtc 実装では `AudioDeviceIOS::StereoPlayoutIsAvailable()` が `false` を返すため、SDK 側で `RTCAudioSession.setPreferredOutputNumberOfChannels:` を呼ぶだけでは効果がない可能性が高い。有効でない場合、SDK 側の対応は WebRTC-Build 側の対応を待つ必要がある。
2. **前提調査 issue が未完了**: `issues/0038-investigate-stereo-audio-receive.md` の調査結果を前提としているが、0038 は `Completed:` 未記入で未完了。
3. **API 設計が未決**: `Configuration` に追加するプロパティの名前・型・デフォルト値が決まっていない。また設定の反映タイミング（接続時自動反映か、`setAudioMode()` への統合か、`configureAudioSession()` 経由の手動設定か）が未決定。

上記の前提条件が解決した時点で `issues/` に戻し、実装着手可能な状態に磨き上げる。

## 目的

Sora から配信されるステレオ音声をステレオのまま再生できるようにする。現状の SDK は音声出力をモノラル前提で扱っており、出力チャンネル数を選択・反映する経路が存在しない。

## 依存関係

- **`issues/0038-investigate-stereo-audio-receive.md`**: 本 issue の前提調査。0038 の完了と調査結果をもって初めて本 issue の実装方針が確定する。0038 で iOS libwebrtc の `StereoPlayoutIsAvailable()` が `false` を返すことが判明している場合、WebRTC-Build 側の改修が必要となり、iOS SDK 側ではその対応を待つ必要がある。
- **WebRTC-Build**: ADM のステレオ playout 設定および Opus デコーダのステレオ再生設定が有効になっていること。
- **`issues/0010-add-stereo-audio-input.md`** (`issues/pending/`): 入力側の対応。出力側と独立して進められるが、設計の一貫性を保つため同様の API 設計パターンを採用することが望ましい。

## 優先度根拠

Low とする。WebRTC-Build 側（ネイティブのオーディオデバイス層・Opus デコード設定）の対応が前提となり、iOS SDK 単独では完結しない。加えて、0038 の調査で iOS の `StereoPlayoutIsAvailable()` が false と確認されており、libwebrtc ADM レイヤーの改修が避けられない可能性が高い。緊急性を示す具体的なユーザー要望も無いため Low とする。

## 現状

### libwebrtc 側の制約

音声出力経路はネイティブの WebRTC オーディオデバイス層に依存している。WebRTC 側には出力チャンネル数を扱う API が存在する:

- `RTCAudioSession` に `setPreferredOutputNumberOfChannels:` がある
- `RTCAudioSessionConfiguration` に `outputNumberOfChannels` がある

しかし、0038 の調査によると iOS の libwebrtc 実装 (`sdk/objc/native/src/audio/audio_device_ios.mm`) では `AudioDeviceIOS::StereoPlayoutIsAvailable()` が `false` を返す。このため、`RTCAudioSession` レベルの API を呼び出しても libwebrtc 内部でチャンネル数が 1 に制限される可能性が高い。

### SDK 側の現状

iOS SDK の音声関連は `Sora/AudioMode.swift` / `Sora/Sora.swift` にあるが、出力チャンネル数（モノラル / ステレオ）を選択・指定する API を持たない。

```swift
public enum AudioOutput {
  case `default`
  case speaker
}
```

`Sora/AudioMode.swift:45`

`AudioOutput` は `default` / `speaker` のみで、ステレオ / モノラルの区別を持たない。`Sora/Configuration.swift` にもチャンネル数関連のプロパティは存在しない。

### 設定反映の候補経路

現在 SDK が `RTCAudioSession` にアクセスする経路は以下があるが、いずれも出力チャンネル数設定は行っていない:

| 経路 | ファイル | 行 | タイミング |
|------|----------|-----|------------|
| `configureAudioSession(block:)` | `Sora/Sora.swift` | 292-297 | ユーザー任意 |
| `setAudioMode(_:options:)` | `Sora/Sora.swift` | 304-347 | 接続完了後（手動） |
| `initializeAudioInput()` | `Sora/PeerChannel.swift` | 543-589 | 接続中 |

`Sora/AudioDeviceModuleWrapper.swift` は録音のポーズ/再開（ハードミュート）のみを扱うラッパーであり、出力チャンネル数の制御とは無関係。

## 設計方針（調査・判断が必要な項目）

以下は実装着手前に結論を出すべき調査・設計判断項目である。これらが未決であることが本 issue の pending 理由の一部となっている。

1. **WebRTC-Build 側の対応状況確認**: ADM のステレオ playout、Opus デコーダのステレオ再生が有効になっているか。`StereoPlayoutIsAvailable()` が `false` のままなら WebRTC-Build 側の改修が必要であり、その完了を待つ。
2. **API 設計の決定**: 以下のいずれかの方針を選択する:
   - `Configuration` に `audioOutputChannels: Int = 1` を追加（将来 5.1ch 等への拡張を考慮）
   - `Configuration` に `audioStereoOutputEnabled: Bool = false` を追加（シンプルな二択）
   - 既存 `AudioOutput` 列挙型を拡張してステレオフラグを持たせる
3. **設定反映タイミングの決定**:
   - `Configuration` プロパティとして接続時に自動反映する
   - `setAudioMode()` 内で `RTCAudioSession.setPreferredOutputNumberOfChannels:` を呼び出す
   - `configureAudioSession(block:)` 経由の手動設定に任せ、SDK 側では API を追加しない
   - どの経路を選ぶ場合も、`RTCAudioSession.setPreferredOutputNumberOfChannels:` と `RTCAudioSessionConfiguration.outputNumberOfChannels` のどちらを使うかを決定する
4. **SDP / Opus stereo=1 の扱い**: 0038 の調査結果を踏まえ、SDP ネゴシエーションで Opus の `stereo=1` パラメーターが必要かどうかを確認する。`RTCAudioSession` レベルの設定だけでは足りず、SDP レベルでの対応が必要な場合の実装を検討する。
5. **エッジケースの検討**:
   - デバイスがステレオ出力をサポートしていない場合のフォールバック
   - Bluetooth オーディオデバイス接続時のチャンネル数制約
   - `bypassVoiceProcessing` とステレオ出力の相互作用（Voice Processing はモノラル前提）
   - `AVAudioSession` カテゴリ変更に伴うチャンネル数設定のリセット有無
   - iPad と iPhone のオーディオハードウェア差異
6. **後方互換性**: 既定はモノラルとし、明示的にステレオを指定した場合のみ挙動が変わるようにする。既存の `configureAudioSession` や音声 API の挙動は変更しない。

## 完了条件

実装着手前の前提条件:
- `issues/0038-investigate-stereo-audio-receive.md` が完了し、ステレオ playout の可否と必要な対応が結論づけられていること
- WebRTC-Build 側で ADM のステレオ playout 設定および Opus デコーダのステレオ再生設定が有効であることが確認されていること
- API 設計（上記「設計方針 2, 3」）の方針が決定され、具体的なプロパティ名・型・デフォルト値が決定していること

実装後の完了条件:
- ステレオ音声出力を有効にする設定が `Configuration` から指定できること
- 指定時に `RTCAudioSession` への出力チャンネル数設定が反映されること
- 既定（未指定）ではモノラルのまま従来挙動を維持すること
- 実機でステレオ再生が確認できること
- `CHANGES.md` の `develop` セクションに以下を追記すること:
  ```
  - [ADD] ステレオ音声出力に対応する
    - @担当者
  ```

## 解決方法
